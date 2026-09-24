#!/usr/bin/env bash
# Build the app for a connected iPhone, install it, launch it with its console
# attached, and save that console, with the setup log (subsystem
# com.origin89.apps), to .build/bench/ios-<time>.log. Runs until the app exits
# or Ctrl-C.
#
#   scripts/ios-bench.sh [device-udid]    (default: the first connected iPhone)
#
# Signing comes from apps/ios/Local.xcconfig (see apps/ios/Signing.xcconfig).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ ! -f apps/ios/Local.xcconfig ]]; then
    echo "apps/ios/Local.xcconfig is missing: set DEVELOPMENT_TEAM there (see apps/ios/Signing.xcconfig)" >&2
    exit 1
fi

device="${1:-}"
if [[ -z "$device" ]]; then
    devices="$(mktemp)"
    trap 'rm -f "$devices"' EXIT
    xcrun devicectl list devices --json-output "$devices" >/dev/null
    device="$(python3 - "$devices" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("tunnelState") == "connected":
        print(d["hardwareProperties"]["udid"])
        break
PY
)"
fi
if [[ -z "$device" ]]; then
    echo "no connected iPhone: connect one, unlock it and trust this Mac" >&2
    exit 1
fi

xcodebuild -project apps/ios/Origin89.xcodeproj -scheme Origin89 -configuration Debug \
    -destination "id=$device" -derivedDataPath .build/device -allowProvisioningUpdates \
    -quiet build
app=.build/device/Build/Products/Debug-iphoneos/Origin89.app
bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun devicectl device install app --device "$device" "$app" >/dev/null

mkdir -p .build/bench
log=".build/bench/ios-$(date +%Y%m%d-%H%M%S).log"
echo "console: $log"
# OS_ACTIVITY_DT_MODE mirrors the unified log, info and debug included, to the console.
xcrun devicectl device process launch --device "$device" --terminate-existing --console \
    --environment-variables '{"OS_ACTIVITY_DT_MODE":"enable"}' "$bundle" 2>&1 | tee "$log"
