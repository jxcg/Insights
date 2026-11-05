#!/usr/bin/env bash
# Runs the test suite on an iOS simulator new enough for the app.
#
#   scripts/test.sh                                  # whole suite
#   scripts/test.sh InsightsTests/BaselineMathTests  # one suite (or test)
#
# Picks the simulator itself: an available iPhone whose iOS version is at least
# the project's deployment target, preferring "iPhone 17". Set SIMULATOR_ID to
# a device UDID to choose one yourself.
#
# On CI (CI=true) a missing simulator is installed and created rather than
# treated as an error, since hosted runners do not always ship devices for the
# newest runtime.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$repo_root/Insights/Insights.xcodeproj"
preferred_device="iPhone 17"

# read from the project, so this script never disagrees with Xcode about it
min_ios="$(grep -m1 -o 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]*' "$project/project.pbxproj" \
    | grep -o '[0-9.]*$' || true)"
if [[ -z "$min_ios" ]]; then
    echo "error: no IPHONEOS_DEPLOYMENT_TARGET found in $project/project.pbxproj" >&2
    exit 1
fi

# prints the UDID of the best matching simulator, or nothing
find_simulator() {
    xcrun simctl list devices available --json | python3 -c '
import json, sys

min_version = tuple(([int(part) for part in sys.argv[1].split(".")] + [0, 0])[:3])
preferred = sys.argv[2]

def version_of(runtime_key):
    # keys look like com.apple.CoreSimulator.SimRuntime.iOS-27-2
    if ".SimRuntime.iOS-" not in runtime_key:
        return None
    try:
        parts = [int(part) for part in runtime_key.rsplit("iOS-", 1)[1].split("-")]
    except ValueError:
        return None
    # padded so 27.2 and 27.2.0 compare equal and 27.2.1 sorts above both
    return tuple((parts + [0, 0])[:3])

candidates = []
for runtime_key, devices in json.load(sys.stdin)["devices"].items():
    version = version_of(runtime_key)
    if version is None or version < min_version:
        continue
    for device in devices:
        if device["name"].startswith("iPhone"):
            # preferred name first, then the newest runtime
            candidates.append((device["name"] != preferred, tuple(-v for v in version), device["udid"]))

if candidates:
    print(sorted(candidates)[0][2])
' "$min_ios" "$preferred_device"
}

# CI only: install the selected Xcode's iOS runtime if needed, then create a
# device on it
create_simulator() {
    local pair
    pair="$(runtime_and_device_type)"
    if [[ -z "$pair" ]]; then
        echo "No iOS $min_ios+ simulator runtime installed; downloading one." >&2
        xcodebuild -downloadPlatform iOS >&2
        pair="$(runtime_and_device_type)"
    fi
    if [[ -z "$pair" ]]; then
        echo "error: still no iOS $min_ios+ runtime with an iPhone after download." >&2
        xcrun simctl list runtimes >&2
        exit 1
    fi

    local runtime_id="${pair% *}" device_type="${pair#* }"
    echo "Creating a simulator on $runtime_id ($device_type)." >&2
    xcrun simctl create "Insights CI" "$device_type" "$runtime_id"
}

# prints "<runtime id> <device type id>": an available iOS runtime at or above
# the deployment target, and an iPhone that runtime supports. Some runtimes
# exist only for one model (iPhone Duo's has an -iPhone19-4 suffix), so the
# runtime's own list of supported devices decides, never a guess. Prefers the
# preferred device name, then the newest runtime.
runtime_and_device_type() {
    xcrun simctl list runtimes available --json | python3 -c '
import json, sys
min_version = tuple(([int(part) for part in sys.argv[1].split(".")] + [0, 0])[:3])
preferred = sys.argv[2]

def version_of(text):
    try:
        parts = [int(p) for p in text.split(".")]
    except ValueError:
        return None
    # padded so 27.2 and 27.2.0 compare equal and 27.2.1 sorts above both
    return tuple((parts + [0, 0])[:3])

candidates = []
for runtime in json.load(sys.stdin)["runtimes"]:
    version = version_of(runtime.get("version", ""))
    if runtime.get("platform") != "iOS" or not runtime.get("isAvailable", True):
        continue
    if version is None or version < min_version:
        continue
    for device in runtime.get("supportedDeviceTypes", []):
        if device.get("productFamily") == "iPhone" or device.get("name", "").startswith("iPhone"):
            candidates.append((
                device["name"] != preferred,
                tuple(-v for v in version),
                len(runtime["identifier"]),  # the general runtime over a single-model one
                runtime["identifier"],
                device["identifier"],
            ))

if candidates:
    best = sorted(candidates)[0]
    print(best[3], best[4])
' "$min_ios" "$preferred_device"
}

simulator_id="${SIMULATOR_ID:-$(find_simulator)}"
if [[ -z "$simulator_id" ]]; then
    if [[ "${CI:-}" == "true" ]]; then
        simulator_id="$(create_simulator)"
    else
        echo "error: no iPhone simulator running iOS $min_ios or later." >&2
        echo "Install one in Xcode > Settings > Components, or set SIMULATOR_ID." >&2
        exit 1
    fi
fi

echo "Xcode: $(xcodebuild -version | head -1)"
echo "Testing on simulator $simulator_id (iOS $min_ios minimum)"

only_testing=()
for filter in "$@"; do
    only_testing+=("-only-testing:$filter")
done

xcodebuild test \
    -project "$project" \
    -scheme Insights \
    -destination "id=$simulator_id" \
    ${only_testing[@]+"${only_testing[@]}"}
