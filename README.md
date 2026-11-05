# Insights

An application which integrates Apple's Core ML models (Apple Foundation Models) with HealthKit to provide accurate insights about your health, with tight integration around Apple's Health ecosystem.

## Running

A simulator has no Health data, so the app starts empty. To run with 90 days of
mock history data instead, add the following launch argument in Xcode:

1. Open **Edit Scheme**.
2. Select **Run** and open the **Arguments** tab.
3. Add `-sampleData` to **Arguments Passed On Launch**.

## Requirements

* Xcode 27.2 or later (iOS 27.2 SDK)
* iOS 27.2 or later, on device or simulator

## Testing

Run the test suite from the repository root:

```bash
scripts/test.sh                                   # whole suite
scripts/test.sh InsightsTests/BaselineMathTests   # one suite or test
```

The script picks an iPhone simulator running at least the app's deployment
target, preferring iPhone 17. Set `SIMULATOR_ID` to a device UDID to choose one
yourself. CI runs the same script.

`scripts/screenshots.sh` launches the app on that simulator and saves
screenshots of the Summary (sample data) and the first-launch screen to
`screenshots/`. CI runs it after the tests and uploads the images. It
reinstalls the app on that simulator, which clears the app's local data there.
