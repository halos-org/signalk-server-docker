# Verification

`verify-image.sh` is the only gate between a green build and an image that is
wrong. Two distinct failure modes have to be caught, and the second is the one
that is easy to miss:

1. A package lands where Signal K does not discover it — builds clean, serves
   nothing.
2. A package lands where Signal K *does* discover it and shadows one
   signalk-server itself needs — builds clean, serves everything, and silently
   downgrades the server's own dependencies.

```bash
./run build && ./run verify
```

Set `BASE` to enable the two comparisons against the base image (CI does):

```bash
BASE=signalk/signalk-server:v2.30.0-core ./run verify
```

## What it asserts, and why each one

| Assertion | Catches |
|---|---|
| Every manifest entry appears in the union of `/skServer/plugins` and `/skServer/webapps` | Packages installed where discovery does not look |
| …at the version baked into the image | A stale copy shadowing the baked one; a hybrid package tree |
| Every manifest webapp serves 200 with a body at its URL | A webapp present in the listing whose payload is missing — the listing is a `package.json` keyword scan, not evidence anything is served |
| Nothing loads that is neither in the manifest nor in the base image | A plugin arriving as another plugin's dependency and shipping enabled-by-default |
| Every dependency signalk-server declares resolves as it does in the base image | The bake displacing the server's own dependency closure |
| `/admin/` serves 200 with a body | The bake displacing the base image's admin UI — not a manifest entry, so the webapp loop does not cover it |
| Manifest parsed to a non-zero count | A parsing change that makes the whole check vacuous |

The expected set is read from `plugins.list` at run time, never hardcoded —
hardcoding lets a silently-dropped package pass.

The union matters: `/skServer/webapps` filters out packages whose plugin is not
enabled, and the image enables nothing, so most entries appear only in the
plugins listing.

## Mutation table

**Re-run this whenever the script's assertions change, or whenever anything the
harness reads changes.** A check never observed failing is not evidence that it
can fail. Last run 2026-08-06, against the nested-install design with the
filesystem-walk probe:

| Mutation | Expected | Observed |
|---|---|---|
| Hoisted install, whole staging tree copied into the server root | resolution assertion fails | **35** displacements reported, incl. `ws:8.21.0->7.5.13`, `bcryptjs:2.4.3->3.0.3`, `JSONStream:1.3.5->0.7.4` |
| Copy to top-level `node_modules` instead of the server root | plugin assertions fail | 17/17 reported not loaded |
| `npm install` in place at `/home/node/signalk` | plugin assertions fail, admin UI breaks | 16/17 not loaded, admin UI **500** |
| `public/` deleted from a webapp package | webapp assertion fails | webapp reported as not serving |
| Manifest entry absent from the image | that entry reported not loaded | named entry failed |
| Manifest containing only comments | vacuity guard fires | guard fired, 0 entries |
| Unmutated control | passes | PASS |

### Lessons this table has already paid for

**The probe strategy matters as much as the assertion.** The first attempt at
the resolution check used `require.resolve('<pkg>/package.json')`, which throws
`ERR_PACKAGE_PATH_NOT_EXPORTED` for any package with a restrictive `exports`
map — 13 of signalk-server's 61 declared dependencies, `bcryptjs` among them.
Those were silently dropped, and the comparison ignored packages that had
*disappeared* entirely. It reported **5** of 35 real displacements and passed an
image that had lost every security header. The current probe walks the
filesystem across the whole closure and reports 35.

**The first version of this harness passed the hoisted build.** Every plugin
loaded, the admin UI served, and 35 of signalk-server's own dependencies had
been silently substituted — including a `ws` major downgrade on the WebSocket
layer every instrument streams over. Assertions that only ask "did the things I
added load?" cannot see what those things displaced. The dependency-comparison
row exists because of that miss.

**A structural check is weaker than a behavioural one, and can be weaker than it
looks.** An earlier `require.resolve('serialport')` check was reported as
catching "the bake pruning a base-image dependency". It resolved the *top-level*
copy, which this Dockerfile never touches, so it could not fail for anything the
bake does. It was replaced by the base-image comparison above.

**Presence in a listing is not evidence of serving.** Deleting only `public/`
from `@halos-org/skip` and `@signalk/freeboard-sk` left the harness green while
both URLs 404'd — webapp discovery is a keyword scan. Hence the payload
assertion.

**Do not use a base-image package for the removal mutation.** Anything
signalk-server ships as a dependency loads whether or not the bake did anything,
so its assertion is unfailable. `plugins.list` deliberately contains none.

**A package being another package's dependency does not make it a plugin.**
`@halos-org/skip-freeboard-panel` and `sk-ais-status-plugin` are dependencies of
`@halos-org/skip`, and under a hoisted install they were discovered as plugins
and enabled by default without ever being curated. Nesting stopped that, which
is correct — but they are wanted, so they are listed explicitly. Only manifest
entries reach the server package root where discovery looks.

## Requirements

`docker`, `curl`, `openssl`, `python3` with `bcrypt`. The bcrypt hash seeds a
`security.json`, because the entrypoint hard-codes `--securityenabled` and the
module listings are 401 without an admin user. `/admin/` and `/signalk` answer
200 unauthenticated; the listings do not.
