#!/bin/zsh
# Build a notarized, stapled Zentic.app and zip it for distribution.
#
#   scripts/release.sh
#
# Steps: archive (Developer ID) → export → notarize → staple → zip. The result is
# build/release/Zentic-<version>.zip, ready to hand to anyone on macOS 26.
#
# Notarization credentials come from a notarytool keychain profile named
# "zentic-notary". This script never sees or stores the credentials themselves.
set -euo pipefail

cd "${0:A:h}/.."

profile=zentic-notary
out=build/release

step() { print -P "%B==> $1%b" }

# MARK: Preflight — everything that can fail fast, before a five-minute archive.

if ! command -v xcodegen >/dev/null; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 69
fi

# The build number is the commit count, so it must describe a commit: a build
# from uncommitted changes could not be reproduced or told apart from the next.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: the working tree has uncommitted changes. Commit or stash them, then release." >&2
  exit 65
fi

if ! security find-identity -v -p codesigning | grep -q '"Developer ID Application'; then
  echo "error: no \"Developer ID Application\" signing identity in the keychain." >&2
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates, then run this again." >&2
  exit 78
fi

if ! notary_check=$(xcrun notarytool history --keychain-profile "$profile" 2>&1); then
  echo "error: no usable notarytool keychain profile named \"$profile\". notarytool said:\n" >&2
  print -r -- "$notary_check" | sed 's/^/  /' >&2
  cat >&2 <<EOF

Create the profile once (it is stored in your login keychain, not in this repo):

  1. Make an app-specific password at https://account.apple.com
     (Sign-In and Security → App-Specific Passwords).
  2. Run, and paste the password when asked:

       xcrun notarytool store-credentials $profile \\
         --apple-id <your Apple ID email> --team-id 5QC5886P5V

Then run this script again.
EOF
  exit 78
fi

build_number=$(git rev-list --count HEAD)

# MARK: Archive and export

step "Archiving build $build_number"
rm -rf "$out"
mkdir -p "$out"
xcodegen generate --quiet
xcodebuild \
  -project Zentic.xcodeproj \
  -scheme Zentic \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$out/Zentic.xcarchive" \
  -derivedDataPath build/DerivedData \
  -quiet \
  CURRENT_PROJECT_VERSION="$build_number" \
  archive

step "Exporting with Developer ID"
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>5QC5886P5V</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$out/Zentic.xcarchive" \
  -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -quiet

app="$out/export/Zentic.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
codesign --verify --deep --strict "$app"

# MARK: Notarize and staple

step "Notarizing $version ($build_number) — usually a few minutes"
# notarytool takes a zip, a dmg or a pkg, not a bare .app.
ditto -c -k --keepParent "$app" "$out/Zentic-notarize.zip"
# A rejected submission ("Invalid") is still a successful submit, so read the
# verdict rather than trusting the exit code, and show Apple's log on rejection
# instead of letting the stapler fail later with "no ticket".
if ! result=$(xcrun notarytool submit "$out/Zentic-notarize.zip" --keychain-profile "$profile" \
    --wait --output-format json); then
  print -r -- "$result" >&2
  exit 1
fi
rm "$out/Zentic-notarize.zip"
verdict=$(print -r -- "$result" | plutil -extract status raw -o - -)
if [[ "$verdict" != Accepted ]]; then
  submission=$(print -r -- "$result" | plutil -extract id raw -o - -)
  echo "error: notarization came back \"$verdict\". Apple's log:" >&2
  xcrun notarytool log "$submission" --keychain-profile "$profile" >&2
  exit 1
fi

step "Stapling"
# Stapling attaches the ticket to the app, so Gatekeeper accepts it offline.
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

# MARK: Package

zip="$out/Zentic-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

# Auto-update slots in here: sign "$zip" for Sparkle and add it to the appcast.

step "Done"
echo "$PWD/$zip"
