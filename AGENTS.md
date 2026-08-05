# signalk-server-docker

**LAST MODIFIED**: 2026-08-05

Builds the Signal K server image HaLOS Marine runs: upstream's `-core` variant with a
curated set of plugins and webapps baked in at build time. Published to
`ghcr.io/halos-org/signalk-server-docker` and pinned by exact tag in
`halos-marine-containers/apps/signalk-server/docker-compose.yml`.

Upstream publishes `full` and `-core` variants; the only difference between them is
`--omit=optional` over signalk-server's own `optionalDependencies`. Baking a curated
set is the same mechanism, with our list instead of theirs.

## The constraint that shapes the Dockerfile

Signal K discovers modules under `<appPath>/node_modules`, where `appPath` is the
**signalk-server package root** — `/home/node/signalk/node_modules/signalk-server/`,
not the top-level `node_modules`. A plain `npm install` hoists to the top level,
where discovery never looks.

Worse, the base image's `/home/node/signalk/package-lock.json` still records
`@signalk/server-admin-ui` as a top-level dependency even though upstream's own
Dockerfile physically relocated that scope into the server's nested `node_modules`.
An in-place `npm install` reifies against that lockfile, undoes the relocation, and
**breaks the admin UI**.

Measured, all three variants built and run:

| Approach | Curated packages loaded | Admin UI |
|---|---|---|
| Staging prefix → copy into server root | 16/16 | 200 |
| In-place `npm install` | 1/16 | **500** |
| Copy to top-level `node_modules` | 1/16 | 200 |

So: resolve the manifest in an isolated prefix, then copy into the server package
root **without clobbering** existing entries, so a plugin's older transitive
`@signalk/*` cannot shadow the API the server was built against.

Install with `--ignore-scripts`. Both the app store (`runNpm` passes
`--save --ignore-scripts`) and the retired provisioning hook did, so a baked plugin
and one updated through the admin UI are built the same way.

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

The published tag is `<upstream version>-<BUILD>`, e.g. `2.30.0-1`. The version
half is read from the base image's own installed `signalk-server/package.json`
at build time -- **not** parsed out of `BASE`. Whatever upstream calls its tags
is upstream's business; what is actually installed is the fact we publish. The
Dockerfile never mentions a version, so an upstream bump does not touch it.

- Upstream bump: set `BASE`, reset `BUILD=1`
- Plugin change or rebuild: increment `BUILD`

`./run version` prints what the current `build.env` would publish, without
building anything.

Published tags are never reused. Nothing is pinned (see below), so two builds of
one commit can differ -- the marine app pins by name, and republishing a tag
would swap content underneath a verification that already passed. CI fails if the
tag exists; increment `BUILD`.

The shared `version-bump-check` workflow is deliberately **not** wired in: it
excludes `docker/` and `Dockerfile` from its "package-affecting" set on the
assumption that a Dockerfile is dev tooling. Here the Dockerfile is the payload,
so it would report success having inspected nothing. There is no `VERSION` file
and no bumpversion config; both exist elsewhere in the workspace as bumpversion's
anchor, and this repo has no semver of its own to anchor.

## Plugin versions are not pinned

Deliberately, matching upstream: `docker/Dockerfile_rel` runs
`npm install signalk-server@$TAG` with no lockfile, and its bundled plugins are
semver ranges (`^4.0.0`, `0.x`). Our curated set resolves the same way, so a
baked plugin and a fresh app-store install agree.

The cost is that a published tag's contents are not recorded in the repo. That is
recoverable from the artifact itself -- every package's `package.json` ships in
the image:

```bash
./run plugin-versions ghcr.io/halos-org/signalk-server-docker:2.30.0-1
```

CI runs this on every build and writes it to the job summary, so "which versions
were in that tag?" is answerable from the run that produced it.

## Changing the plugin set

1. Edit `plugins.list` (LF only — `.gitattributes` pins it; the parser is line-based)
2. Increment `BUILD` in `build.env`
3. Merge; CI builds, verifies and publishes the new tag
4. Repin the tag in `halos-marine-containers/apps/signalk-server/docker-compose.yml`
   and bump that app's `metadata.yaml`

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
