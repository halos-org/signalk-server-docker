#!/usr/bin/env bash
#
# usage: .github/scripts/check-base-update.sh
#
# Report whether upstream published a base image newer than the one build.env
# pins, and stage the bump if so: BASE to the newer reference, BUILD back to 1 --
# the upstream-bump procedure in AGENTS.md, performed by a machine.
#
# Outputs (GITHUB_OUTPUT): has_update, new_base
# On an update it rewrites build.env and writes the PR body to /tmp/pr_body.md.
#
# Safe to run locally: it only edits a tracked file, and the edit is a diff.

set -o nounset
set -o pipefail
set -o errexit

cd "$(dirname "$0")/../.."

# shellcheck source=/dev/null
source ./build.env

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
PR_BODY=/tmp/pr_body.md

# The tag upstream published, verbatim -- selected from what the registry lists,
# never composed here. build.env's rule is that the shape of BASE is upstream's
# business; deriving a pattern from the tag we already pin keeps it that way.
LATEST_BASE="$(python3 - "$BASE" <<'PYEOF'
import json
import re
import sys
import urllib.request

base = sys.argv[1]

# Split off the tag only. A registry host may carry a port, so the tag is what
# follows the last colon *after* the last slash.
repo, sep, tag = base.rpartition(":")
if not sep or "/" in tag:
    sys.exit(f"BASE carries no tag: {base}")
if "." in repo.split("/")[0] or ":" in repo.split("/")[0]:
    sys.exit(f"BASE is not a Docker Hub reference, and only Docker Hub is queried here: {base}")
path = repo if "/" in repo else f"library/{repo}"

# Digit runs become wildcards and everything else has to match literally, so the
# variants upstream also publishes -- -alpine-core, -beta.2, two-component
# v2.30-core, the sha- and master- CI tags -- are excluded by construction
# rather than by a list of things to skip.
pattern = re.compile(
    "^" + "".join(
        r"[0-9]+" if part.isdigit() else re.escape(part)
        for part in re.split(r"([0-9]+)", tag) if part
    ) + "$"
)


# Docker Hub refuses an anonymous request whose pagination offset reaches 1000
# ("pagination offset too large for anonymous requests; sign in to page
# further"), so 100 x 10 is the whole anonymous budget, not a tuning choice.
PAGE_SIZE = 100
MAX_PAGES = 10


def newest_tags(path):
    # `ordering=last_updated` is newest first. Docker Hub inverts the usual sign
    # convention -- `-last_updated` is the *ascending* one -- so the sign here is
    # deliberate and not a typo. It is passed explicitly rather than relying on
    # this also being the default order.
    #
    # The window is a fixed size rather than a walk that stops at the pinned tag,
    # because a re-push moves that tag to the top of the listing and a walk that
    # stopped there would skip every release below it.
    url = (f"https://hub.docker.com/v2/repositories/{path}/tags"
           f"?page_size={PAGE_SIZE}&ordering=last_updated")
    for _ in range(MAX_PAGES):
        with urllib.request.urlopen(url, timeout=30) as response:
            page = json.load(response)
        yield from page.get("results", [])
        url = page.get("next")
        if not url:
            return


def buildable(entry):
    # arm64 only, so a tag with no arm64 image is not a candidate however new it
    # is. Deliberately not the entry's `status`: that field is pull-recency
    # telemetry, not a property of the artifact -- it flips to "inactive" on a
    # tag nobody has pulled for about six weeks, and back to "active" the moment
    # anyone does. Filtering on it would drop a real release that had sat
    # unmerged that long, which is the silent staleness this check exists to end.
    return any(
        image.get("architecture") == "arm64" and image.get("os") == "linux"
        for image in entry.get("images", [])
    )


def version(name):
    # Every shaped name shares the pinned tag's literal skeleton, so comparing
    # its digit runs is exact rather than a semver approximation.
    return tuple(int(d) for d in re.findall(r"[0-9]+", name))


scanned = list(newest_tags(path))
shaped = [entry for entry in scanned if pattern.match(entry["name"])]
older = [entry["name"] for entry in shaped if version(entry["name"]) < version(tag)]

# What a truncated window has to establish is coverage: that it reaches back past
# the pin's own release, so no newer release can sit below it. Finding the *pin*
# in the window does not establish that, because a tag's position here is its
# last-pushed time, which upstream can move. Re-push the pinned tag and it
# reappears at the top however old its release is, vouching for a window that may
# no longer reach the releases after it.
#
# A release older in version than the pin is the anchor instead. Upstream
# publishes releases in ascending version order, so anything newer than the pin
# was pushed after that anchor; the window is contiguous and newest first, so
# everything pushed after the anchor is inside it. Nothing upstream does to the
# pin moves the anchor.
#
# This also fails on a listing that stops being newest first, which fills the
# window with tags too old to contain any shaped release at all.
# A window that ran out of pages before it ran out of budget is the whole
# listing, and needs no anchor.
if not older and len(scanned) >= PAGE_SIZE * MAX_PAGES:
    sys.exit(f"{path}: the {len(scanned)} most recently pushed tags contain no release older than "
             f"{tag}, so they cannot be shown to contain every release newer than it; "
             "the listing order changed, or the pin is too old to reach anonymously")

candidates = [entry["name"] for entry in shaped if buildable(entry)]
if not candidates:
    # The pinned tag is the control: build.yml builds from it on every merge, so
    # it demonstrably has an arm64 image. If nothing shaped like it appears to
    # have one, the listing changed shape or the filter is wrong -- and an empty
    # candidate list would otherwise collapse to the pinned tag and report calm.
    sys.exit(f"{path}: {len(shaped)} tags match the shape of {tag}, none with a linux/arm64 image; "
             "the listing or the filter is wrong, which is not the same as up to date")
print(f"{path}: scanned the {len(scanned)} most recently pushed tags, "
      f"{len(shaped)} shaped like {tag}, {len(candidates)} with a linux/arm64 image",
      file=sys.stderr)

# The pinned tag is the floor whether or not it is still listed, which is what
# makes a deleted or de-published tag unable to produce a downgrade.
newest = max(candidates + [tag], key=version)
print(f"{repo}:{newest}")
PYEOF
)"

if [ "$LATEST_BASE" = "$BASE" ]; then
  echo "Up to date: ${BASE}"
  echo "has_update=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "Update: ${BASE} -> ${LATEST_BASE}"

OLD_BASE="$BASE"
OLD_BUILD="$BUILD"

STAGED="$(mktemp)"
trap 'rm -f "$STAGED"' EXIT
sed -e "s|^BASE=.*|BASE=${LATEST_BASE}|" -e "s|^BUILD=.*|BUILD=1|" build.env > "$STAGED"
cp "$STAGED" build.env

# A sed that matched nothing leaves a file that still builds the old image and a
# PR that claims otherwise. Read back what the build will actually read.
# shellcheck source=/dev/null
source ./build.env
[ "$BASE" = "$LATEST_BASE" ] || { echo "build.env rewrite left BASE at ${BASE}" >&2; exit 1; }
[ "$BUILD" = "1" ] || { echo "build.env rewrite left BUILD at ${BUILD}" >&2; exit 1; }

cat > "$PR_BODY" <<EOF
## Upstream base image update

|  | Current | New |
|---|---|---|
| \`BASE\` | \`${OLD_BASE}\` | \`${LATEST_BASE}\` |
| \`BUILD\` | \`${OLD_BUILD}\` | \`1\` |

Only \`build.env\` changes. The published tag's version half is read from the
base image's own installed \`signalk-server\` at build time, so it follows from
\`BASE\` without anything else being edited.

The plugin set is deliberately unpinned, so this rebuild re-resolves every
curated package too. CI writes the resolved versions to the build's job summary.

Upstream release notes: https://github.com/SignalK/signalk-server/releases

Merging publishes the new image tag and stops there. Repin
\`halos-marine-containers/apps/signalk-server/docker-compose.yml\` and bump that
app's \`metadata.yaml\` to put it on a device.
EOF

{
  echo "has_update=true"
  echo "new_base=${LATEST_BASE}"
} >> "$GITHUB_OUTPUT"

echo ""
echo "=== PR body ==="
cat "$PR_BODY"
