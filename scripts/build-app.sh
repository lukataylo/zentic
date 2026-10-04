#!/bin/zsh
# Build Zentic.app from project.yml.
#
#   scripts/build-app.sh            # Debug, signed "Apple Development"
#   scripts/build-app.sh --release  # Release, signed "Developer ID Application"
#
# Prints the path of build/Zentic.app on success. The equivalent by hand:
#
#   xcodegen generate
#   xcodebuild -project Zentic.xcodeproj -scheme Zentic -configuration Debug \
#     -derivedDataPath build/DerivedData -allowProvisioningUpdates build
#
# For a notarized build to hand to someone else, use scripts/release.sh.
set -euo pipefail

cd "${0:A:h}/.."

configuration=Debug
case "${1:-}" in
  "") ;;
  --release) configuration=Release ;;
  *) echo "usage: $0 [--release]" >&2; exit 64 ;;
esac

if ! command -v xcodegen >/dev/null; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 69
fi

xcodegen generate --quiet

# -quiet keeps the output to warnings and errors, so a failure is readable.
xcodebuild \
  -project Zentic.xcodeproj \
  -scheme Zentic \
  -configuration "$configuration" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  -quiet \
  build

# ditto, not cp: it preserves the bundle's symlinks and extended attributes,
# and replacing the whole bundle means no stale file survives from a previous build.
rm -rf build/Zentic.app
ditto "build/DerivedData/Build/Products/$configuration/Zentic.app" build/Zentic.app

echo "$PWD/build/Zentic.app"
