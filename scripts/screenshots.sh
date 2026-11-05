#!/usr/bin/env bash
# Launches the app on the simulator and screenshots it, so a screen that
# crashes at launch is caught, not only a failing unit test.
#
#   scripts/screenshots.sh              # into screenshots/
#   scripts/screenshots.sh some/folder
#
# Takes two: the Summary on sample data, and the first-launch empty state.
# Each starts from a fresh install. Fails if the app is not running a few
# seconds after launch, and prints its memory at that point. Uses
# the same simulator and build folder as scripts/test.sh, so after a test run
# the build is close to free.
#
# Reinstalls the app on that simulator, which clears its local data.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$repo_root/Insights/Insights.xcodeproj"
out="${1:-$repo_root/screenshots}"
derived="$repo_root/build/DerivedData"

# the app's own identifier, not the test bundle's
bundle_id="$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [^;]*' "$project/project.pbxproj" \
    | grep -v Tests | head -1 | sed 's/.*= //')"
if [[ -z "$bundle_id" ]]; then
    echo "error: no app bundle identifier found in the project" >&2
    exit 1
fi

simulator_id="${SIMULATOR_ID:-$("$repo_root/scripts/test.sh" --print-simulator)}"
echo "Screenshots of $bundle_id on simulator $simulator_id"

xcodebuild build \
    -project "$project" \
    -scheme Insights \
    -configuration Debug \
    -destination "id=$simulator_id" \
    -derivedDataPath "$derived" \
    -quiet
app="$derived/Build/Products/Debug-iphonesimulator/Insights.app"

xcrun simctl boot "$simulator_id" 2>/dev/null || true
xcrun simctl bootstatus "$simulator_id" -b >/dev/null
# the same clock and battery in every shot, so two runs compare cleanly
xcrun simctl status_bar "$simulator_id" override \
    --time 9:41 --batteryState charged --batteryLevel 100 || true
mkdir -p "$out"

# fresh install, launch with the given arguments, wait, check it is still
# alive, then take the picture
shoot() {
    local name="$1"
    shift
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    xcrun simctl uninstall "$simulator_id" "$bundle_id" 2>/dev/null || true
    xcrun simctl install "$simulator_id" "$app"

    # prints "<bundle id>: <pid>"; simulator apps are ordinary Mac processes.
    # A freshly booted simulator can refuse the first launch, so try three
    # times.
    local pid="" attempt
    for attempt in 1 2 3; do
        if pid="$(xcrun simctl launch "$simulator_id" "$bundle_id" "$@" | awk -F': ' '{print $2}')" \
            && [[ -n "$pid" ]]; then
            break
        fi
        echo "Launch attempt $attempt failed; retrying." >&2
        sleep 5
    done
    sleep 10
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        echo "error: $name: the app was not running 10 s after launch" >&2
        # what the app logged before it went, since a crash leaves no picture
        xcrun simctl spawn "$simulator_id" log show --last 2m --style compact \
            --predicate 'process == "Insights"' >&2 || true
        exit 1
    fi
    xcrun simctl io "$simulator_id" screenshot "$out/$name.png" >/dev/null
    # the app's own memory ("physical footprint", what iOS counts against
    # an app), and resident memory, which also counts shared system libraries
    local rss footprint
    rss="$(ps -o rss= -p "$pid" | tr -d ' ' || true)"
    footprint="$(vmmap --summary "$pid" 2>/dev/null | awk -F': *' '/^Physical footprint:/ {print $2; exit}' || true)"
    echo "Saved $out/$name.png · footprint ${footprint:-unknown} · resident $(( ${rss:-0} / 1024 )) MB"
}

shoot summary-sample-data -sampleData
shoot first-launch

xcrun simctl status_bar "$simulator_id" clear || true
