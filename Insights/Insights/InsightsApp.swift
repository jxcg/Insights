//
//  InsightsApp.swift
//  Insights
//
//  Created by Joshua Ng on 11/07/2026.
//

import SwiftUI
import SwiftData

@main
struct InsightsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: DailyMetricRecord.self)
    }
}
