import SwiftUI
import SwiftData

/// Insights turns your Apple Health data into a short, honest read on what
/// your body has been doing lately.
///
/// The path there is deliberate. Swift does all the judging: what changed,
/// which way it moved, and whether it is worth any concern. It packs the answer
/// into a Finding. Apple's on-device language model only rephrases a Finding
/// into plainer English. It never sees a raw sample and never decides what the
/// numbers mean.
///
///     Apple Health → local cache → analytics engine → Finding → narration
///
/// Every file in the app sits somewhere on that line, and its doc comment says
/// where. No health data leaves the device.
@main
struct InsightsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.container)
    }

    // running with the `-sampleData` launch argument swaps this for invented
    // history, so the app can be driven end to end on a simulator with no
    // phone and no Health authorisation
    @MainActor
    private static let container: ModelContainer = {
        #if DEBUG
        if SampleData.isEnabled {
            return SampleData.container()
        }
        #endif
        return try! ModelContainer(
            for: DailyMetricRecord.self, SleepNightRecord.self, SyncAnchorRecord.self)
    }()
}
