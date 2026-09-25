#!/bin/zsh
# Builds SimDrop.app, zips it, and publishes it as a GitHub release for the version in VERSION.
#   ./scripts/release.sh            # release VERSION
#   ./scripts/release.sh --draft    # create the release as a draft
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(cat VERSION)
TAG="v$VERSION"
ZIP="build/SimDrop-$VERSION.zip"

./scripts/build-app.sh
rm -f "$ZIP"
# ditto keeps the bundle's symlinks, permissions and signature intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent build/SimDrop.app "$ZIP"
shasum -a 256 "$ZIP"

gh release create "$TAG" "$ZIP" --title "SimDrop $VERSION" --notes-file - "$@" <<NOTES
Universal build for Apple Silicon and Intel Macs, macOS 15 or later.

### Install
1. Download **SimDrop-$VERSION.zip**, unzip it, and move **SimDrop.app** to Applications.
2. The app is not notarized, so macOS blocks the first launch. Either:
   - open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway**, or
   - run \`xattr -dr com.apple.quarantine /Applications/SimDrop.app\`
3. SimDrop appears in the menu bar and docks a toolbar beside each open simulator.

Needs Xcode (for \`xcrun simctl\`).
NOTES
