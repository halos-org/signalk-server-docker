# Supplied from build.env by ./run build and CI; no default, so an unset BASE
# fails the build loudly instead of silently pinning a stale version.
ARG BASE

# Resolve the curated set in an isolated prefix.
#
# Installing into /home/node/signalk directly would reify against that tree's
# package-lock.json, which still records @signalk/server-admin-ui as a top-level
# dependency even though upstream's own Dockerfile relocated that scope into
# node_modules/signalk-server/node_modules/@signalk/. npm re-hoists it, drops the
# nested copy, and the admin UI returns 500. Measured, not theorised -- see
# AGENTS.md for the three-variant comparison.
FROM ${BASE} AS deps

USER node
WORKDIR /staging

COPY --chown=node:node plugins.list .

# --install-strategy=nested keeps every transitive dependency under the package
# that needs it, leaving only the manifest's own entries at the staging root.
# This is load-bearing, not a preference: a hoisted install puts ~380 packages at
# the root, and copying those into the server package root places them CLOSER in
# Node's resolution chain than the server's own dependencies at
# /home/node/signalk/node_modules. Measured on a hoisted build, 35 packages
# resolved differently for signalk-server's own code -- including ws 8.21.0 ->
# 7.5.13, a major downgrade of the WebSocket layer, and bcryptjs 2.4.3 -> 3.0.3
# on the login path. Upstream's own docker/Dockerfile uses nested for the same
# reason.
#
# --ignore-scripts matches the Signal K app store (runNpm passes
# --save --ignore-scripts) and the provisioning hook this image replaces, so a
# baked plugin and one updated through the admin UI are built the same way. It
# also keeps third-party install scripts out of a CI job holding a registry token.
#
# Comments are stripped only at line start: an npm spec may legitimately contain
# '#' (github:org/repo#ref), and a mid-line strip would silently install the
# default branch instead of the pinned ref.
RUN npm init -y >/dev/null \
 && sed -e 's/^[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' plugins.list | tr -d '\r' \
      | xargs npm install --install-strategy=nested --ignore-scripts --no-audit --no-fund \
 && rm package.json package-lock.json

# Assemble the payload HERE, in the throwaway stage. Doing it in the final stage
# would COPY the whole 913-package staging tree into a layer first; deleting it
# afterwards does not reclaim the bytes, because layers are additive -- it shipped
# 223 MB of a directory that does not exist at runtime.
#
# Only the manifest's own entries, whole-directory, refusing rather than merging
# on collision. cp --update=none would skip colliding *files* and descend into the
# directory, producing a package whose package.json describes one version while
# carrying files from another. Entries are deduplicated so a repeated line reports
# itself rather than blaming the base image.
RUN set -eu; \
    mkdir -p /staging/curated; \
    n=0; \
    for pkg in $(sed -e 's/^[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' plugins.list | tr -d '\r' | sort -u); do \
      [ -d "/staging/node_modules/$pkg" ] || { echo "manifest entry did not install as a directory named '$pkg' -- entries must be bare package names, not version or git specs" >&2; exit 1; }; \
      mkdir -p "/staging/curated/$(dirname "$pkg")"; \
      cp -r "/staging/node_modules/$pkg" "/staging/curated/$pkg"; \
      n=$((n + 1)); \
    done; \
    echo "staged $n curated packages"; \
    rm plugins.list

# The collision guard lives here, not in the final stage: this stage is FROM the
# same base, so it can see the server root the payload will land in. Checking here
# lets the final stage be a single direct COPY -- staging through /tmp there would
# leave the whole payload in an extra layer that a later rm cannot reclaim.
RUN set -eu; \
    dest=/home/node/signalk/node_modules/signalk-server/node_modules; \
    cd /staging/curated; \
    for pkg in $(find . -mindepth 1 -maxdepth 1 ! -name '@*' -printf '%f\n'; find . -mindepth 2 -maxdepth 2 -path './@*' -printf '%P\n'); do \
      [ -e "$dest/$pkg" ] && { echo "refusing to overwrite a package the base image provides: $pkg" >&2; exit 1; }; \
      true; \
    done; \
    echo "no collisions with the base image"

FROM ${BASE}

USER node

# Signal K discovers modules under <appPath>/node_modules, where appPath is the
# signalk-server package root -- not the top-level node_modules, where a plain
# npm install would hoist them. The guard below fails the build rather than
# merging if the base image already provides one of these.
COPY --from=deps --chown=node:node \
     /staging/curated/ /home/node/signalk/node_modules/signalk-server/node_modules/
