//
//  InsightsApp.swift
//  Insights
//
//  Created by Joshua Ng on 11/07/2026.
//

import SwiftUI
import SwiftData

/// Insights turns your Apple Health data into a short, honest read on what
/// your body has been doing lately.
///
/// The path there is deliberate. Swift does all the judging — what changed,
/// which way it moved, and whether that is worth any concern — and packs the
/// answer into a Finding. Apple's on-device language model only ever rephrases
/// a Finding into plainer English; it never sees a raw sample and never
/// decides what the numbers mean.
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
        .modelContainer(for: [DailyMetricRecord.self, SleepNightRecord.self, SyncAnchorRecord.self])
    }
}
