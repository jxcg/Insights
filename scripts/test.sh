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

min_version = tuple(int(part) for part in sys.argv[1].split("."))
preferred = sys.argv[2]

def version_of(runtime_key):
    # keys look like com.apple.CoreSimulator.SimRuntime.iOS-27-2
    if ".SimRuntime.iOS-" not in runtime_key:
        return None
    try:
        return tuple(int(part) for part in runtime_key.rsplit("iOS-", 1)[1].split("-"))
    except ValueError:
        return None

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
    local runtime_id
    runtime_id="$(newest_ios_runtime)"
    if [[ -z "$runtime_id" ]]; then
        echo "No iOS $min_ios+ simulator runtime installed; downloading one." >&2
        xcodebuild -downloadPlatform iOS >&2
        runtime_id="$(newest_ios_runtime)"
    fi
    if [[ -z "$runtime_id" ]]; then
        echo "error: still no iOS $min_ios+ runtime after download." >&2
        exit 1
    fi

    local device_type
    device_type="$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
types = [t for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone")]
preferred = [t for t in types if t["name"] == sys.argv[1]]
print((preferred or types)[-1]["identifier"] if types else "")
' "$preferred_device")"

    echo "Creating a simulator on $runtime_id ($device_type)." >&2
    xcrun simctl create "Insights CI" "$device_type" "$runtime_id"
}

# prints the identifier of the newest available iOS runtime at or above the
# deployment target, or nothing
newest_ios_runtime() {
    xcrun simctl list runtimes available --json | python3 -c '
import json, sys
min_version = tuple(int(part) for part in sys.argv[1].split("."))
def version_of(text):
    try:
        return tuple(int(p) for p in text.split("."))
    except ValueError:
        return None

runtimes = [
    (version_of(r["version"]), r["identifier"])
    for r in json.load(sys.stdin)["runtimes"]
    if r.get("platform") == "iOS" and r.get("isAvailable", True)
]
runtimes = [r for r in runtimes if r[0] is not None and r[0] >= min_version]
print(max(runtimes)[1] if runtimes else "")
' "$min_ios"
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
