# signalk-server-docker

The Signal K server image HaLOS Marine runs: upstream's `-core` variant with a curated
set of marine plugins and webapps baked in at build time.

Published to `ghcr.io/halos-org/signalk-server-docker`, pinned by exact tag in
[`halos-marine-containers`](https://github.com/halos-org/halos-marine-containers).

## Why a custom image

Upstream publishes two variants. `full` bundles a fixed set of optional webapps HaLOS
does not all want; `-core` bundles none. The difference between them is a single npm
flag over signalk-server's own `optionalDependencies` — so building `-core` plus our
own list is upstream's own mechanism, with our curation.

Baking at build time means a plugin that cannot be installed fails CI rather than a
boat, and no `npm install` runs when the container starts.

Plugins stay independently updatable: an update through the Signal K admin UI writes
to the data volume, which shadows the image copy and wins permanently. Plugins baked
into the image cannot be *removed* through the admin UI, matching how upstream's `full`
image has always behaved.

## Usage

```bash
./run version      # print the tag build.env would publish
./run build        # build locally for this machine's architecture
./run verify       # assert the built image actually loads every curated package
./run help         # all commands
```

## Changing the plugin set

Edit `plugins.list`, increment `BUILD` in `build.env`, and open a PR. CI builds,
verifies and publishes the new tag; then repin it in `halos-marine-containers`.

Plugin versions are not pinned, matching upstream. To see what a built or
published image actually resolved to, `./run plugin-versions [image]`.

`plugins.list` is LF-only and parsed line by line. Comments start with `#`.

## Following upstream

A scheduled workflow checks daily whether upstream published a newer release of
the image `BASE` pins, and opens a PR moving `BASE` to it and resetting `BUILD`
to 1. The PR is opened with a repo-scoped token, so `build.yml` runs on it as an
ordinary check, and auto-merge lands it once that check is green — no human is
in this path. The decision about whether an upstream release should reach a
device is made later, at the repin in `halos-marine-containers`.

## Development notes

See [AGENTS.md](AGENTS.md) — in particular why the Dockerfile resolves the manifest in
a staging prefix rather than installing in place, which is not obvious and is the
difference between an image that works and one that publishes green with a dead admin
UI.

## License

MIT — see [LICENSE](LICENSE).
