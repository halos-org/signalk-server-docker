# signalk-server-docker

**THESE RULES ONLY APPLY TO FILES IN /signalk-server-docker/**

**LAST MODIFIED**: 2026-08-16

## For agentic coding: use the HaLOS workspace

Work from the `halos` workspace repository rather than this repo alone -- the
full context across sibling repos matters, and the workspace AGENTS.md above
this one governs too.

Builds the Signal K server image HaLOS Marine runs: upstream's `-core` variant with a
curated set of plugins and webapps baked in at build time. Published to
`ghcr.io/halos-org/signalk-server-docker` and pinned by exact tag in
`halos-marine-containers/apps/signalk-server/docker-compose.yml`.

Upstream publishes `full` and `-core` variants; the only difference between them is
`--omit=optional` over signalk-server's own `optionalDependencies`. Baking a curated
set is the same mechanism, with our list instead of theirs.

## The two constraints that shape the Dockerfile

**Where plugins must land.** Signal K discovers modules under
`<appPath>/node_modules`, where `appPath` is the **signalk-server package root** —
`/home/node/signalk/node_modules/signalk-server/`, not the top-level
`node_modules`. A plain `npm install` hoists to the top level, where discovery
never looks.

Installing *in place* is the obvious alternative and breaks the admin UI: the
base image's `package-lock.json` still records `@signalk/server-admin-ui` as a
top-level dependency even though upstream's Dockerfile physically relocated that
scope into the server's nested `node_modules`. npm reifies against the lockfile,
undoes the relocation, and `/admin/` returns 500.

**What must not land there.** The server root is *closer* in Node's resolution
chain than the top level, where signalk-server's own 569 dependencies live. So
anything copied into the server root shadows the server's own dependencies for
its own code. A hoisted install puts ~380 packages there, and measured, 35 of
them resolved differently than upstream shipped:

```
ws        8.21.0 -> 7.5.13   declared ^8.17.0 — major downgrade of the WebSocket layer
bcryptjs  2.4.3  -> 3.0.3    declared ^2.4.3  — the login path
uuid      8.3.2  -> 14.0.1   declared ^8.3.2
```

It still ran, because the server happens to use `ws.Server`/`ws.OPEN`, which
exist in both majors. `ws.WebSocketServer` was `undefined`.

So: `--install-strategy=nested` keeps every transitive dependency under the
package that needs it, leaving only the manifest's own entries at the staging
root, and the copy step takes **only those entries**, whole-directory, refusing
rather than merging on collision. Upstream's own `docker/Dockerfile` uses nested
for the same reason.

Measured across variants:

| Approach | Manifest loaded | Server root | Server deps displaced | Admin UI |
|---|---|---|---|---|
| Nested + manifest-only copy | all | 26 | **0** | 200 |
| Hoisted + copy whole tree | all | 429 | **35** | 200 |
| In-place `npm install` | 1 | — | — | **500** |
| Copy to top-level `node_modules` | 1 | — | — | 200 |

A file-granular copy (`cp --update=none`) is not sufficient: it skips colliding
*files* and descends into the directory, producing a package whose `package.json`
describes one version while carrying files from another.

Install with `--ignore-scripts`. Both the app store (`runNpm` passes
`--save --ignore-scripts`) and the retired provisioning hook did, so a baked
plugin and one updated through the admin UI are built the same way.

Strip manifest comments **only at line start**: an npm spec may legitimately
contain `#` (`github:org/repo#ref`), and a mid-line strip would silently install
a default branch instead of a pinned ref.

## Verification is behavioural, never structural

A naive Dockerfile builds green and produces an image where nothing loads. Files on
disk prove nothing — a package in the wrong directory is present and undiscoverable,
which is exactly the failure mode.

`tests/verify-image.sh` starts the image and asks the running server what it loaded.
It also asserts the base image's own contents survived, because the bake mutates a
tree upstream hand-relocated. During the spike the structural check
(`require.resolve` on the admin UI package) **passed** while the HTTP check returned
500 — the directory survived, something it needed did not. Keep the HTTP assertion.

The entrypoint hard-codes `--securityenabled`. `/admin/` and `/signalk` answer 200
unauthenticated, but the module listings are 401, so the script seeds a
`security.json` and logs in for a token. Poll `/signalk` for readiness, not
`/signalk/v1/api/`, which is 401 even when the server is fully up.

When changing the script's assertions, re-run the mutation table in
`tests/README.md`. A check never observed failing is not evidence.

## Versioning

Everything versionable lives in `build.env`, and nothing is derived from git
history, git tags, or CI state:

```
BASE=signalk/signalk-server:v2.30.0-core   # verbatim, never parsed
BUILD=1                                    # our revision of that base
```

The published tag is `v<upstream version>-halos.<BUILD>`, e.g. `v2.30.0-halos.2`,
matching what `ghcr.io/hatlabs/homarr` publishes. The `-halos.` separator is the
only thing that tells a consumer which half is upstream's and which is ours.

`check-image-updates.sh` in `shared-workflows` splits these tags on `-halos.`, so
the marine app's repin bot writes the half before it as `upstream_version` and
our build revision does not leak into a field defined as upstream's.

The version half is read from the base image's own installed
`signalk-server/package.json` at build time -- **not** parsed out of `BASE`.
Whatever upstream calls its tags is upstream's business; what is actually
installed is the fact we publish. The Dockerfile never mentions a version, so an
upstream bump does not touch it.

- Upstream bump: set `BASE`, reset `BUILD=1` -- proposed daily by a scheduled
  check, see *Watching upstream*
- Plugin change or rebuild: increment `BUILD`

`BUILD` reaches the build as a build-arg, and the dependency-resolving layer
reads it. That is what makes incrementing it re-resolve rather than replay a
cached install -- see *Plugin versions are not pinned*.

`./run version` prints what the current `build.env` would publish, without
building anything.

Published tags are never reused. Nothing is pinned (see below), so two builds of
one commit can differ -- the marine app pins by name, and republishing a tag
would swap content underneath a verification that already passed. CI fails if the
tag exists; increment `BUILD`.

The shared `version-bump-check` workflow is not wired in. The decisive reason is
that its repo-level block is gated on a `VERSION` file existing, and this repo has
none, so calling it would be a no-op. Secondarily, it excludes `docker/` and
`Dockerfile` from its "package-affecting" set on the assumption a Dockerfile is
dev tooling — so even with a `VERSION` file it would miss this repo's main
payload, though `plugins.list` and `build.env` are not excluded and would be
checked. There is no bumpversion config either; it exists elsewhere in the
workspace as bumpversion's anchor, and this repo has no semver of its own.

## Plugin versions are not pinned

Deliberately, matching upstream: `docker/Dockerfile_rel` runs
`npm install signalk-server@$TAG` with no lockfile, and its bundled plugins are
semver ranges (`^4.0.0`, `0.x`). Our curated set resolves the same way, so a
baked plugin and a fresh app-store install agree.

Unpinned resolution and a layer cache do not combine on their own. CI builds with
`cache-from: type=gha`, and with `plugins.list` unchanged the install layer is a
cache hit, so every version stays frozen at whatever the cache first resolved --
while `./run version` reports a new tag and CI publishes it. `v2.31.1-halos.1`
and `-halos.2` are the same content for that reason: the second was cut to pick
up `signalk-questdb-history-provider` 2.0.0 and baked 1.0.0, four days after
1.10.0 reached npm. `BUILD` is now a build-arg the resolve layer reads, so a
`BUILD` increment misses the cache by construction. Read the *Record resolved
plugin versions* step, not the tag, to know what a build actually took.

The cost is that a published tag's contents are not recorded in the repo. That is
recoverable from the artifact itself -- every package's `package.json` ships in
the image:

```bash
./run plugin-versions ghcr.io/halos-org/signalk-server-docker:v2.30.0-halos.2
```

CI runs this on every build and writes it to the job summary, so "which versions
were in that tag?" is answerable from the run that produced it.

## Watching upstream

Nothing else watches `BASE`. The marine app pins *our* image, so its daily image
check follows our GHCR tags and never looks at upstream's.

`check-upstream.yml` runs `.github/scripts/check-base-update.sh` daily: it lists
the most recently pushed tags of the repository `BASE` names, keeps those shaped
like the tag `BASE` pins, and opens a PR setting `BASE` to the newest of them and
`BUILD` back to 1.

The shape is derived from the pinned tag -- digit runs wildcarded, everything
else literal -- so `-alpine-core`, `-beta.2`, two-component `v2.30-core` and the
per-commit `sha-`/`master-` tags are excluded by construction rather than by a
list of things to skip, and upstream's tag format stays upstream's business. A
candidate also has to carry a linux/arm64 image, and the pinned tag is always
the floor, so a tag upstream deletes cannot produce a downgrade.

Only Docker Hub is queried; a `BASE` on any other registry exits non-zero rather
than reporting up to date.

The listing is narrowed, then read to its end. Upstream carries ~2800 tags,
nearly all of them per-commit CI tags, and Docker Hub refuses an anonymous
request whose pagination offset reaches 1000 (`pagination offset too large for
anonymous requests`) -- so the full listing is not reachable without a
credential, and it has to be made smaller before it can be read whole.

The narrowing is Docker Hub's `name` substring filter, given the longest literal
run of the pinned tag -- the parts the shape pattern does not wildcard. Every
name the pattern can match contains those literals, so a filter built from them
cannot drop a candidate. For `v2.30.0-core` that literal is `-core`, and it takes
2790 tags down to 294. It is a narrowing hint and not the matching rule: the
pattern still decides what counts, so extra tags getting through changes nothing.

Reading to the end is what makes the answer sound, and truncating is unsound in a
way ordering does not fix. This listing is ordered by last-pushed time, which
upstream can move by re-pushing any tag at any time. So no cut-off point within
it can be shown to have every release above it -- not the pinned tag's position,
which a re-push of the pin moves, and not an older release's position, which a
re-push of that tag moves. Any check of the form "we looked far enough back
because tag X is in view" is defeated by upstream re-pushing X.

The script fails rather than reporting calm when the narrowed listing does not
end within the anonymous budget, when the pinned tag has no literal to narrow by,
when no tag matches the pinned shape, or when none of the matching tags appears
to have an arm64 image -- the pinned tag is the control for the last two, since
the build pulls it on every merge. This whole check exists because a silent gap
went unnoticed.

There is no automated test for any of this -- the detection has no seam to inject
a listing through, which is issue #8. The guards were exercised by hand against
the live listing.

Note what is *not* used: the listing's per-image `status`. It reports pull
recency, not existence -- it flips to `inactive` on a tag nobody has pulled for
about six weeks, and back the moment anyone does. An `inactive` image pulls
normally. Filtering on it would silently drop a real release that had sat
unmerged that long, which is the failure this check exists to end.

The detection is a script rather than a `./run` command because `run` is in
build.yml's paths filter -- a command added there would put every merge touching
it on the publish path, where it resolves an already published tag and fails.

The PR is opened with the `BUMP_PAT` secret, not `GITHUB_TOKEN`. A PR opened
with `GITHUB_TOKEN` raises no `pull_request` event, so build.yml would never
attach a check to it -- the bump would arrive unevaluated, which is the one
thing it exists to get evaluated. `BUMP_PAT` is a fine-grained token scoped to
this repo alone with `Contents: write` and `Pull requests: write`; the workflow
refuses to start without it rather than falling back, because the fallback opens
a PR that merely *looks* fine, and an expired token would degrade to that
silently.

`main` carries a ruleset requiring the `build` check, pinned to the GitHub
Actions integration so a status of that name from another source cannot satisfy
it, with an empty `bypass_actors` and no force-push or deletion.

Be precise about what that buys, because it is less than it looks. Required
approvals are zero -- deliberately, since the end state is an unattended merge --
and on a `pull_request` event the workflow producing the `build` check comes from
the PR head, so a PR defines its own gate. What the ruleset guarantees is that a
change to `main` arrived through a PR and that GitHub Actions reported `build` on
it. It does **not** contain `BUMP_PAT`: that token holds `Contents: write` and
`Pull requests: write`, which is everything needed to push a branch, make its own
check green, and merge it. The credential is the trust boundary here, not the
ruleset.

Because that ruleset is the only thing making auto-merge wait for anything, the
daily check asserts it before arming anything and fails when it is missing. Not
theatre: without a required check GitHub considers the bump PR mergeable the
moment it opens, and `gh` drops `--auto` and merges it outright -- publishing a
bump nothing built, with every workflow green. An unasserted precondition is
fine while a human clicks merge; it is not fine once nobody does.

The PR then merges itself. Auto-merge is armed on it and the ruleset holds it
until `build` is green -- indefinitely, if it never is. No human is in this path:
**every upstream release publishes a `-halos.N` image, including a major.** The
image is inert until something pins it, so a release that builds but should not
ship is judged at the `halos-marine-containers` repin, which stays a human merge
and doubles as the notice that a new image exists. A release that is genuinely
broken fails `verify-image.sh` and leaves the PR red and unmerged.

Nothing here can decline a bump, by design. Do not add a mechanism that halts on
a human touching the branch: the pipeline exists to build our image for every
upstream release without being asked.

Auto-merge must be armed with `BUMP_PAT` and not `GITHUB_TOKEN` for the same
reason the PR is opened with it. GitHub completes an auto-merge on behalf of
whoever armed it; armed by `GITHUB_TOKEN`, the resulting push to `main` would
raise no event, `build.yml` would never publish, and every workflow in the chain
would still be green.

Three smaller things in that step are load-bearing and easy to undo by accident.
The step refuses to run off the default branch, because `checkout` takes the
dispatched ref and the push renames *that* ref's tip -- a dispatch from a feature
branch would otherwise publish the whole branch as a bump and merge it. The PR
lookup filters `isCrossRepository`, because `--head` matches a ref *name* across
every fork on this public repo. And the merge is pinned to the head SHA this run
produced, because `gh` merges outright instead of arming whenever GitHub already
considers the PR mergeable.

## Changing the plugin set

1. Edit `plugins.list` (LF only — `.gitattributes` pins it; the parser is line-based)
2. Increment `BUILD` in `build.env`
3. Merge; CI builds, verifies and publishes the new tag
4. Repin the tag in `halos-marine-containers/apps/signalk-server/docker-compose.yml`
   and bump that app's `metadata.yaml`. `test_image_is_the_baked_one_at_an_exact_tag`
   there asserts the tag shape, so it moves with the pin.

Do not add packages that signalk-server already ships as non-optional dependencies.
`@signalk/course-provider` is one: it loads whether or not the bake did anything, so
it makes a vacuous assertion, and installing it risks overwriting the version the
server was built against.

## Architecture

arm64 only. HaLOS is an arm64 Raspberry Pi OS distribution and the marine app is this
image's only consumer. Builds run on a native `ubuntu-24.04-arm` runner — never QEMU,
which would emulate the `npm install` that dominates the build. Add amd64 only if an
x86 target actually appears.

## Related

- `halos-marine-containers` — the consumer; pins this image and owns `prestart.sh`
- `signalk-server` (hatlabs fork) — upstream source; `docker/Dockerfile_rel` shows the
  relocation technique, `src/config/config.ts` defines `appPath`
