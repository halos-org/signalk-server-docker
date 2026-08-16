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
import urllib.parse
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

# The pinned tag's literal runs -- the parts the shape pattern does not wildcard
# -- appear in every name that pattern can match. So the longest of them is a
# substring `every candidate contains`, and asking Docker Hub to return only
# the tags containing it cannot drop one. For v2.30.0-core that is `-core`,
# which is 294 of upstream's 2790 tags.
#
# This is a narrowing hint, not the matching rule: `pattern` still decides what
# counts, so a filter that lets extra tags through changes nothing.
NARROW = max(re.split(r"[0-9]+", tag), key=len)
if not NARROW:
    sys.exit(f"{tag} is all digits, so there is no literal to narrow the listing by; "
             "the whole listing is not reachable without a credential")


def matching_tags(path):
    # Read the narrowed listing to its end. Truncating it would be unsound in a
    # way no amount of ordering fixes: this listing is ordered by last-pushed
    # time, which upstream can move by re-pushing any tag, so no cut-off point
    # within it can be shown to have every release above it.
    query = urllib.parse.urlencode({"page_size": PAGE_SIZE, "name": NARROW})
    url = f"https://hub.docker.com/v2/repositories/{path}/tags?{query}"
    entries = []
    for _ in range(MAX_PAGES):
        with urllib.request.urlopen(url, timeout=30) as response:
            page = json.load(response)
        entries += page.get("results", [])
        url = page.get("next")
        if not url:
            return entries
    sys.exit(f"{path}: more than {PAGE_SIZE * MAX_PAGES} tags contain {NARROW!r}, so the listing "
             "cannot be read to its end anonymously; narrowing it further needs a credential")


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


scanned = matching_tags(path)
shaped = [entry for entry in scanned if pattern.match(entry["name"])]
if not shaped:
    # The pinned tag matches its own pattern and contains NARROW, so an empty
    # result means the listing did not contain it: upstream restructured its tags
    # or the API changed shape. Either way the answer is not "up to date".
    sys.exit(f"{path}: no tag matches the shape of {tag}; check upstream")

candidates = [entry["name"] for entry in shaped if buildable(entry)]
if not candidates:
    # The pinned tag is the control: build.yml builds from it on every merge, so
    # it demonstrably has an arm64 image. If nothing shaped like it appears to
    # have one, the listing changed shape or the filter is wrong -- and an empty
    # candidate list would otherwise collapse to the pinned tag and report calm.
    sys.exit(f"{path}: {len(shaped)} tags match the shape of {tag}, none with a linux/arm64 image; "
             "the listing or the filter is wrong, which is not the same as up to date")
print(f"{path}: {len(scanned)} tags contain {NARROW!r}, {len(shaped)} shaped like {tag}, "
      f"{len(candidates)} with a linux/arm64 image",
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
