# Verification

`verify-image.sh` is the only thing standing between a green build and an image
where nothing loads. A Dockerfile that puts the curated packages in the wrong
directory builds without error, starts without error, and serves no plugins.

```bash
./run build && ./run verify
```

## What it asserts, and why each one

| Assertion | Catches |
|---|---|
| Every `plugins.list` entry appears in the union of `/skServer/plugins` and `/skServer/webapps` | Packages installed to a directory Signal K does not discover |
| Manifest parsed to a non-zero count | A parsing change that silently makes the whole check vacuous |
| `/admin/` returns 200 with a non-empty body | The bake displacing the base image's own admin UI |
| `serialport` resolves from the server package root | The bake pruning a base-image dependency as extraneous |

The expected set is read from `plugins.list` at run time rather than hardcoded.
Hardcoding lets a silently-dropped package pass.

The union matters: `/skServer/webapps` filters out packages whose plugin is not
enabled, and the image enables nothing, so most curated entries appear only in
the plugins listing.

## Mutation table

**Re-run this whenever the script's assertions change, or whenever anything the
harness reads changes.** A check never observed failing is not evidence that it
can fail. Last run 2026-08-06, after the versioning rework:

| Mutation | Expected result | Observed |
|---|---|---|
| Copy packages to top-level `node_modules` instead of the server root | plugin assertions fail | 15/16 reported not loaded |
| `npm install` in place at `/home/node/signalk` | plugin assertions fail, admin UI breaks | 15/16 not loaded, admin UI **500** |
| Add a manifest entry absent from the image | that entry reported not loaded | named entry failed |
| Manifest containing only comments | vacuity guard fires | guard fired, 0 entries |

Two things that table taught, worth keeping:

**The structural check is weaker than the behavioural one.** Under the in-place
mutation, `require.resolve` on the admin-UI package succeeded while the HTTP
request returned 500. The directory survived; something it needed did not. Never
substitute a file or resolve check for asking the running server.

**`@signalk/course-provider` is a vacuous assertion.** It is a non-optional
dependency of signalk-server, so the stock `-core` image already serves it — it
loaded even under the no-relocation mutation. Do not use it as the removed
package when re-running the mutation table, and think twice before adding other
server dependencies to the manifest.

## Requirements

`docker`, `curl`, `openssl`, `python3` with `bcrypt`. The bcrypt hash seeds a
`security.json`, because the entrypoint hard-codes `--securityenabled` and the
module listings are 401 without an admin user. `/admin/` and `/signalk` answer
200 unauthenticated; the listings do not.
