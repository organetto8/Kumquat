#!/bin/bash
# Publishes the files `make release` left in build/ as a GitHub release for the version in VERSION.
# The notes are that version's section of CHANGELOG.md followed by the install instructions.
# A hyphenated version (1.1.0-beta.1) becomes a pre-release; anything else becomes Latest.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
TAG="v$VERSION"
FILES=("build/Kumquat-$VERSION.dmg" "build/Kumquat-$VERSION.zip" "build/SHA256SUMS.txt")

fail() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first"
for file in "${FILES[@]}"; do [[ -f "$file" ]] || fail "$file is missing: run make release"; done
built="$(plutil -extract CFBundleShortVersionString raw build/Kumquat.app/Contents/Info.plist)"
[[ "$built" == "$VERSION" ]] || fail "build/Kumquat.app is $built, VERSION says $VERSION: run make release"
gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists"

# The lines between "## [VERSION]" and the next heading or link reference.
changes="$(awk -v heading="## [$VERSION]" '
    index($0, heading) == 1 { found = 1; next }
    found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    found { print }
' CHANGELOG.md | sed -e '/./,$!d')"
[[ -n "$changes" ]] || fail "CHANGELOG.md has no section for $VERSION"

notes="$changes

## Install

1. Download **Kumquat-$VERSION.dmg** below.
2. Open it and drag **Kumquat** onto **Applications** (replace the old version if asked).
3. Open Kumquat. The app is not notarised, so the first time macOS blocks it: go to
   **System Settings ▸ Privacy & Security** and click **Open Anyway**.

Requires macOS 14 Sonoma or later. Universal build for Apple silicon and Intel.
Full instructions: [User guide](https://github.com/organetto8/Kumquat/blob/main/docs/USER_GUIDE.md) ·
all changes: [CHANGELOG](https://github.com/organetto8/Kumquat/blob/main/CHANGELOG.md)."

flags=(--title "Kumquat $VERSION" --verify-tag)
publish=(--draft=false)
if [[ "$VERSION" == *-* ]]; then flags+=(--prerelease); else publish+=(--latest); fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Kumquat $VERSION"
git push origin HEAD "refs/tags/$TAG"
# Releases are immutable once published, so the files go into a draft first.
printf '%s\n' "$notes" | gh release create "$TAG" --draft "${flags[@]}" --notes-file - "${FILES[@]}"
gh release edit "$TAG" "${publish[@]}"
