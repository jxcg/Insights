# Insights
An application which integrates Apple's Core ML models (Apple Foundation Models) with HealthKit to provide accurate insights about your health, with tight integration around Apple's Health ecosystem.

## Running

A simulator has no Health data, so the app starts empty. To run on 90 days of
invented history instead: Edit Scheme → Run → Arguments → add `-sampleData`.

```sh
xcodebuild test -project Insights/Insights.xcodeproj -scheme Insights \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
