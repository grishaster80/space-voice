#!/bin/bash
# Publishes a build for Homebrew: only the signed app goes out, the source stays private.
#   scripts/release.sh 0.2.0
# Uploads SpaceVoice-<version>.zip to a release of grishaster80/homebrew-tap (public,
# so anyone can download it) and commits Casks/space-voice.rb there. Then:
#   brew install --cask grishaster80/tap/space-voice
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAP_REPO="${TAP_REPO:-grishaster80/homebrew-tap}"
TAG="space-voice-v$VERSION"
ZIP="build/SpaceVoice-$VERSION.zip"

git diff --quiet && git diff --cached --quiet || { echo "Commit your changes first." >&2; exit 1; }
git tag -f "v$VERSION"
VERSION="$VERSION" scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent build/SpaceVoice.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

gh release create "$TAG" "$ZIP" --repo "$TAP_REPO" --title "Space Voice $VERSION" \
  --notes "Space Voice $VERSION. Install: \`brew install --cask grishaster80/tap/space-voice\`"

TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q
mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" -e "s#__TAP_REPO__#$TAP_REPO#" \
  packaging/space-voice.rb > "$TAP_DIR/Casks/space-voice.rb"
git -C "$TAP_DIR" add Casks/space-voice.rb
git -C "$TAP_DIR" commit -q -m "space-voice $VERSION"
git -C "$TAP_DIR" push -q
git push -q origin "v$VERSION"
echo "Released $VERSION: brew install --cask grishaster80/tap/space-voice"
