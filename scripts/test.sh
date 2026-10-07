#!/bin/zsh
# Every test Zentic has, with a summary at the end.
#
#   scripts/test.sh            # Swift (unit + integration), web, UI
#   scripts/test.sh --no-ui    # without the UI tests, which take over the
#                              # keyboard and pointer for a few minutes
#
# Steps:
#   swift      swift test: ZenticKitTests (core logic) and ZenticMacTests
#              (real tabs and web views against a local fixture server)
#   web        cd web && npm run check: typecheck, vitest, bundle build
#   ui         xcodebuild test: ZenticUITests, XCUITest journeys through the
#              app (needs xcodegen, and Automation Mode — macOS asks once)
#
# Nothing touches your data or the internet: every test run keeps its data in
# a directory of its own, and pages come from Tests/Fixtures/Pages on 127.0.0.1.
# Logs and the UI tests' result bundle (screenshots of failures) go to
# build/test-results/.
set -uo pipefail

cd "${0:A:h}/.."

ui=1
for arg in "$@"; do
  case "$arg" in
    --no-ui) ui=0 ;;
    *) echo "usage: $0 [--no-ui]" >&2; exit 64 ;;
  esac
done

results=build/test-results
mkdir -p "$results"
summary=()
failed=0

# step <name> <command...>: run it, keep its output, note the outcome.
step() {
  local name=$1; shift
  local log="$results/$name.log"
  local start=$SECONDS
  print -P "%B▸ $name%b"
  if "$@" > "$log" 2>&1; then
    summary+=("✔ $name  $((SECONDS - start))s")
  else
    summary+=("✘ $name  $((SECONDS - start))s  — see $log")
    failed=1
    # The lines that say what broke.
    grep -E "✘|error:|FAIL|failed|Error:" "$log" | grep -v "^\s*$" | head -20
  fi
}

step swift swift test

if [[ ! -d web/node_modules ]]; then
  print "Installing web dependencies (once)…"
  (cd web && npm ci --no-audit --no-fund) > "$results/npm-ci.log" 2>&1
fi
step web zsh -c "cd web && npm run check"

if (( ui )); then
  if ! command -v xcodegen >/dev/null; then
    summary+=("✘ ui  — xcodegen not found: brew install xcodegen")
    failed=1
  elif pgrep -qf "Zentic.app/Contents/MacOS/Zentic"; then
    # XCUITest quits a running copy of the app it tests before launching its own.
    summary+=("✘ ui  — Zentic.app is running; quit it first (swift run copies are fine)")
    failed=1
  else
    xcodegen generate --quiet
    rm -rf "$results/UI.xcresult"
    step ui xcodebuild test \
      -project Zentic.xcodeproj -scheme Zentic -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build/DerivedData \
      -allowProvisioningUpdates -resultBundlePath "$results/UI.xcresult"
    if grep -q "enabling automation mode" "$results/ui.log"; then
      print "macOS wants your password to let the tests drive the app (Automation Mode)."
      print "Run once, as an admin, to stop it asking:"
      print "  sudo automationmodetool enable-automationmode-without-authentication"
    fi
    # Each journey's own line, so a pass says what passed.
    grep -E "Test Case .*(passed|failed)" "$results/ui.log" | sed -E "s/.*\[ZenticUITests\.([A-Za-z]+) ([A-Za-z]+)\]' (passed|failed) \(([0-9.]+) seconds\)./  \3  \1.\2  \4s/"
  fi
fi

print
print -P "%BSummary%b"
for line in "${summary[@]}"; do print "  $line"; done
exit $failed
