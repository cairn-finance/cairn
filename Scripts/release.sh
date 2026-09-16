#!/usr/bin/env bash
#
# Cut a Cairn release from `main`.
#
# Computes the next semantic version from the latest tag, keeps the local
# MARKETING_VERSION in sync, prepends a CHANGELOG entry, commits, tags, and
# pushes. The tag then triggers .github/workflows/release.yml, which archives,
# uploads to TestFlight, and publishes a GitHub Release.
#
# Usage:
#   Scripts/release.sh patch          # 0.1.0 -> 0.1.1
#   Scripts/release.sh minor          # 0.1.0 -> 0.2.0
#   Scripts/release.sh major          # 0.1.0 -> 1.0.0
#   Scripts/release.sh 1.4.2          # explicit version
#
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat >&2 <<'EOF'
Cut a Cairn release from main.

Usage:
  Scripts/release.sh patch    # 0.1.0 -> 0.1.1
  Scripts/release.sh minor    # 0.1.0 -> 0.2.0
  Scripts/release.sh major    # 0.1.0 -> 1.0.0
  Scripts/release.sh 1.4.2    # explicit version
EOF
  exit 2
}

bump="${1:-}"
[ -n "$bump" ] || usage

# --- Preconditions --------------------------------------------------------

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
  echo "error: releases are cut from main, but HEAD is on '$branch'." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean; commit or stash first." >&2
  exit 1
fi

git fetch --tags --quiet origin

# --- Next version ---------------------------------------------------------

latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
latest="${latest_tag#v}"

IFS=. read -r major minor patch <<<"$latest"
if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
  echo "error: latest tag '$latest_tag' is not vX.Y.Z." >&2
  exit 1
fi

case "$bump" in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
  *)
    if [[ "$bump" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      next="$bump"
    else
      echo "error: expected major, minor, patch, or X.Y.Z (got '$bump')." >&2
      exit 2
    fi
    ;;
esac

if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
  echo "error: tag v$next already exists." >&2
  exit 1
fi

echo "Latest tag:  $latest_tag"
echo "Next version: v$next"

# --- Keep the local project version in sync -------------------------------

# XcodeGen owns the project, so the version lives in project.yml. CI overrides
# both values from the tag at build time; this keeps local builds accurate too.
/usr/bin/sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\1\"$next\"/" project.yml

# --- CHANGELOG ------------------------------------------------------------

if [ ! -f CHANGELOG.md ]; then
  cat > CHANGELOG.md <<'EOF'
# Changelog

All notable changes to Cairn are documented here. This project follows
[Semantic Versioning](https://semver.org) and
[Keep a Changelog](https://keepachangelog.com).

EOF
fi

today="$(date -u +%Y-%m-%d)"
entry="$(mktemp)"
{
  echo "## [$next] - $today"
  echo
  if git rev-parse -q --verify "refs/tags/$latest_tag" >/dev/null; then
    git log --no-merges --pretty='- %s (%h)' "$latest_tag..HEAD"
  else
    git log --no-merges --pretty='- %s (%h)' HEAD
  fi
  echo
} > "$entry"

# Insert the new section *after* the file's preamble. Prepending put releases
# above the `# Changelog` heading once the file grew a title and intro.
header="$(mktemp)"
rest="$(mktemp)"
awk -v header="$header" -v rest="$rest" '
  !pastPreamble && /^## \[/ { pastPreamble = 1 }
  { print > (pastPreamble ? rest : header) }
' CHANGELOG.md
cat "$header" "$entry" "$rest" > "$entry.merged"
mv "$entry.merged" CHANGELOG.md
rm -f "$entry" "$header" "$rest"

# --- Commit and tag -------------------------------------------------------

git add project.yml CHANGELOG.md
git commit -m "chore(release): v$next"
git tag -a "v$next" -m "Cairn v$next"

git push origin main
git push origin "v$next"

echo
echo "Pushed v$next. CI is now building, uploading to TestFlight, and creating"
echo "the GitHub Release: https://github.com/sehejjain/cairn/actions"
