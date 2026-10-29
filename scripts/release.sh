#!/bin/bash
# Publishes a release: the signed app goes to this repository's Releases and the
# Homebrew cask in the tap is updated to it.
#   scripts/release.sh 0.2.0
# Then anyone can install it with:
#   brew install --cask grishaster80/tap/space-voice
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
REPO="${REPO:-grishaster80/space-voice}"
TAP_REPO="${TAP_REPO:-grishaster80/homebrew-tap}"
ZIP="build/SpaceVoice-$VERSION.zip"

git diff --quiet && git diff --cached --quiet || { echo "Commit your changes first." >&2; exit 1; }
git tag "v$VERSION"
git push -q origin "v$VERSION"
VERSION="$VERSION" scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent build/SpaceVoice.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Space Voice $VERSION" \
  --notes "Install: \`brew install --cask grishaster80/tap/space-voice\`, or download the zip below."

TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q
mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" -e "s#__REPO__#$REPO#" \
  packaging/space-voice.rb > "$TAP_DIR/Casks/space-voice.rb"
git -C "$TAP_DIR" add Casks/space-voice.rb
git -C "$TAP_DIR" commit -q -m "space-voice $VERSION"
git -C "$TAP_DIR" push -q
echo "Released $VERSION: brew install --cask grishaster80/tap/space-voice"
