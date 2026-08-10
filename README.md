# Insights

An application which integrates Apple's Core ML models (Apple Foundation Models) with HealthKit to provide accurate insights about your health, with tight integration around Apple's Health ecosystem.

## Running

A simulator has no Health data, so the app starts empty. To run with 90 days of
mock history data instead, add the following launch argument in Xcode:

1. Open **Edit Scheme**.
2. Select **Run** and open the **Arguments** tab.
3. Add `-sampleData` to **Arguments Passed On Launch**.

## Testing

Run the test suite from the repository root:

```bash
xcodebuild test -project Insights/Insights.xcodeproj -scheme Insights \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
