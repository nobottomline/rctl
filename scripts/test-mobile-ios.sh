#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
simulator=""
cleanup() {
    if [[ -n "$simulator" ]]; then
        xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
        xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A fresh simulator prevents the hosted app from restoring a developer's real
# relay profile before XCTest starts. Do not reuse or erase personal simulators.
selection=$(xcrun simctl list runtimes --json | node -e '
    const fs = require("node:fs");
    const runtimes = JSON.parse(fs.readFileSync(0, "utf8")).runtimes
        .filter(r => r.isAvailable && r.name.startsWith("iOS ") && Number(r.version.split(".")[0]) >= 16
            && (!process.env.RCTL_IOS_TEST_RUNTIME || r.version === process.env.RCTL_IOS_TEST_RUNTIME))
        .sort((a, b) => b.version.localeCompare(a.version, "en", { numeric: true }));
    for (const runtime of runtimes) {
        const phone = runtime.supportedDeviceTypes?.find(d => d.productFamily === "iPhone");
        if (phone) {
            process.stdout.write(`${runtime.identifier} ${phone.identifier}`);
            process.exit(0);
        }
    }
    console.error("Install an iOS 16+ simulator runtime in Xcode before running controller tests.");
    process.exit(1);
')
read -r runtime device_type <<< "$selection"
simulator=$(xcrun simctl create "RCTL Controller Tests" "$device_type" "$runtime")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
if [[ -n "${RCTL_LAN_TEST_ADDRESS:-}" ]]; then
    # Opt-in, view-only qualification against an operator-supplied device.
    xcrun simctl spawn "$simulator" launchctl setenv RCTL_LAN_TEST_ADDRESS "$RCTL_LAN_TEST_ADDRESS"
fi

# Ad-hoc simulator signing supplies the application identity needed by Keychain.
# No Apple account, development team, device, or provisioning profile is used.
xcodebuild -project mobile/ios/RctlMobile.xcodeproj -scheme 'RCTL Controller' \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
    -parallel-testing-enabled NO -derivedDataPath mobile/ios/.derivedData \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test "$@"
