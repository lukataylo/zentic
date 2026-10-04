#!/bin/zsh
# Build a notarized, stapled Zentic.app and zip it for distribution.
#
#   scripts/release.sh
#
# Steps: archive (Developer ID) → export → notarize → staple → zip → sign for
# Sparkle → appcast. The result, in build/release/updates/, is
# Zentic-<version>.zip and appcast.xml: upload both to a GitHub release tagged
# v<version> (README › Releasing). Nothing is published from here.
#
# Notarization credentials come from a notarytool keychain profile named
# "zentic-notary"; the Sparkle signing key is the login-keychain item
# generate_keys made for account "zentic". This script never sees or stores
# either secret itself.
set -euo pipefail

cd "${0:A:h}/.."

profile=zentic-notary
sparkle_account=zentic
feed=https://github.com/lukataylo/zentic/releases/latest/download/appcast.xml
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

# As in build-app.sh: Xcode writes Sparkle's pin into the root Package.resolved,
# which belongs to Package.swift. Put it back when done.
resolved=$(mktemp)
cp Package.resolved "$resolved"
trap 'cp "$resolved" Package.resolved; rm -f "$resolved"' EXIT

# The tag, the zip's name and its download URL all come from the marketing
# version, which only changes by hand (project.yml). Releasing it twice would
# list two archives at one URL, and replacing the asset would break the older
# entry's signature — so refuse a version that is already out.
version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml)
if [[ -z "$version" ]]; then
  echo "error: no MARKETING_VERSION in project.yml." >&2
  exit 65
fi
published=$(mktemp)
if curl -fsSL "$feed" -o "$published"; then
  if grep -qE "shortVersionString(>|=\")${version//./\\.}[<\"]" "$published"; then
    echo "error: the published appcast already lists $version. Raise MARKETING_VERSION in project.yml." >&2
    exit 65
  fi
else
  rm -f "$published"
fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null \
  || { command -v gh >/dev/null && gh release view "v$version" >/dev/null 2>&1; }; then
  echo "error: v$version is already tagged or released. Raise MARKETING_VERSION in project.yml." >&2
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

# Sparkle's tools come with its Swift package; resolving fetches them.
xcodegen generate --quiet
xcodebuild -resolvePackageDependencies -project Zentic.xcodeproj -scheme Zentic \
  -derivedDataPath build/DerivedData -quiet
sparkle_bin=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
if [[ ! -x "$sparkle_bin/sign_update" ]]; then
  echo "error: Sparkle's tools are missing from $sparkle_bin." >&2
  exit 69
fi

# An update signed with any key but the one in Info.plist is refused by every
# installed copy, so check the pair now rather than after notarizing.
if ! public_key=$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p 2>/dev/null); then
  echo "error: no Sparkle signing key for account \"$sparkle_account\" in the login keychain." >&2
  echo "On the release Mac, import the backup: $sparkle_bin/generate_keys --account $sparkle_account -f <file>" >&2
  exit 78
fi
plist_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/Info.plist)
if [[ "$public_key" != "$plist_key" ]]; then
  echo "error: the keychain's Sparkle key ($public_key) is not the one in App/Info.plist ($plist_key)." >&2
  exit 78
fi

build_number=$(git rev-list --count HEAD)

# MARK: Archive and export

step "Archiving build $build_number"
rm -rf "$out"
mkdir -p "$out"
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
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$built" != "$version" ]]; then
  echo "error: the app says version $built, project.yml says $version." >&2
  exit 1
fi
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

# generate_appcast reads every archive in this folder, so it holds only this one.
updates="$out/updates"
mkdir -p "$updates"
zip="$updates/Zentic-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

# MARK: Sign and add to the appcast

step "Signing for Sparkle"
signature=$("$sparkle_bin/sign_update" --account "$sparkle_account" -p "$zip")

step "Updating appcast.xml"
# Start from the published feed so earlier releases stay listed. There is none
# before the first release; generate_appcast then starts a new one.
if [[ -f "$published" ]]; then
  mv "$published" "$updates/appcast.xml"
  echo "Extending the published appcast."
else
  echo "No published appcast yet; starting one."
fi
# Also signs the feed itself, which Info.plist requires (SURequireSignedFeed).
"$sparkle_bin/generate_appcast" --account "$sparkle_account" \
  --download-url-prefix "https://github.com/lukataylo/zentic/releases/download/v$version/" \
  --link https://github.com/lukataylo/zentic \
  "$updates"

# Ed25519 signatures are deterministic: the appcast must carry exactly the one
# made above, or its newest entry describes some other archive.
if ! grep -qF "$signature" "$updates/appcast.xml"; then
  echo "error: appcast.xml does not carry the signature of $zip." >&2
  exit 1
fi

step "Done. Upload both to a GitHub release tagged v$version:"
echo "$PWD/$zip"
echo "$PWD/$updates/appcast.xml"
