#!/bin/zsh
# Builds SimSling.app, zips it, and publishes it as a GitHub release for the version in VERSION.
#   ./scripts/release.sh            # release VERSION
#   ./scripts/release.sh --draft    # create the release as a draft
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(cat VERSION)
TAG="v$VERSION"
ZIP="build/SimSling-$VERSION.zip"

./scripts/build-app.sh
rm -f "$ZIP"
# ditto keeps the bundle's symlinks, permissions and signature intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent build/SimSling.app "$ZIP"
shasum -a 256 "$ZIP"

gh release create "$TAG" "$ZIP" --title "SimSling $VERSION" --notes-file - "$@" <<NOTES
Universal build for Apple Silicon and Intel Macs, macOS 15 or later.

### Install
1. Download **SimSling-$VERSION.zip**, unzip it, and move **SimSling.app** to Applications.
2. The app is not notarized, so macOS blocks the first launch. Either:
   - open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway**, or
   - run \`xattr -dr com.apple.quarantine /Applications/SimSling.app\`
3. SimSling appears in the menu bar and docks a toolbar beside each open simulator.

Needs Xcode (for \`xcrun simctl\`).
NOTES
