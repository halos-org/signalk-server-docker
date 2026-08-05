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

# --ignore-scripts matches both the Signal K app store (runNpm passes
# --save --ignore-scripts) and the provisioning hook this image replaces, so a
# baked plugin and one updated through the admin UI are built the same way.
# It also keeps third-party install scripts out of a CI job holding a registry
# token.
RUN npm init -y >/dev/null \
 && sed -e 's/#.*//' -e '/^[[:space:]]*$/d' plugins.list | tr -d '\r' \
      | xargs npm install --ignore-scripts --no-audit --no-fund \
 && rm plugins.list package.json package-lock.json

FROM ${BASE}

USER node

# Signal K discovers modules under <appPath>/node_modules, where appPath is the
# signalk-server package root -- not the top-level node_modules, where a plain
# npm install would hoist them.
#
# --update=none leaves the server's own @signalk/* in place so a plugin's older
# transitive copy cannot shadow the API the server was built against. (Not -n,
# whose behaviour coreutils documents as non-portable and subject to change.)
COPY --from=deps --chown=node:node /staging/node_modules /tmp/curated
RUN cp -r --update=none /tmp/curated/. \
      /home/node/signalk/node_modules/signalk-server/node_modules/ \
 && rm -rf /tmp/curated
