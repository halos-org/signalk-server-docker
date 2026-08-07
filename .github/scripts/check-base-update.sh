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


def all_tags(path):
    # Docker Hub caps page_size at 100 and this repository has thousands of
    # tags, the vast majority of them per-commit CI tags. Release tags sit at an
    # arbitrary page, so every page is read: a listing truncated at some page
    # count would report "up to date" for a release it never looked at.
    url = f"https://hub.docker.com/v2/repositories/{path}/tags?page_size=100"
    pages = 0
    while url:
        if pages >= 100:
            sys.exit(f"{path}: still paginating after {pages} pages; refusing to guess")
        with urllib.request.urlopen(url, timeout=30) as response:
            page = json.load(response)
        yield from page.get("results", [])
        url = page.get("next")
        pages += 1


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


shaped = [entry for entry in all_tags(path) if pattern.match(entry["name"])]
if not shaped:
    # The pinned tag matches its own pattern, so an empty result means the
    # listing did not contain it: upstream restructured its tags or the API
    # changed shape. Either way the answer is not "up to date".
    sys.exit(f"{path}: no tag matches the shape of {tag}; check upstream")

candidates = [entry["name"] for entry in shaped if buildable(entry)]
if not candidates:
    # The pinned tag is the control: build.yml builds from it on every merge, so
    # it demonstrably has an arm64 image. If nothing shaped like it appears to
    # have one, the listing changed shape or the filter is wrong -- and an empty
    # candidate list would otherwise collapse to the pinned tag and report calm.
    sys.exit(f"{path}: {len(shaped)} tags match the shape of {tag}, none with a linux/arm64 image; "
             "the listing or the filter is wrong, which is not the same as up to date")
print(f"{path}: {len(shaped)} tags shaped like {tag}, {len(candidates)} with a linux/arm64 image",
      file=sys.stderr)

# Every candidate shares the pinned tag's literal skeleton, so ordering by its
# digit runs is exact. The pinned tag is the floor whether or not it is still
# listed, which is what makes a deleted or de-published tag unable to produce a
# downgrade.
newest = max(candidates + [tag], key=lambda name: tuple(int(d) for d in re.findall(r"[0-9]+", name)))
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
