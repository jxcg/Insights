//
//  ContentView.swift
//  Insights
//
//  Created by Joshua Ng on 11/07/2026.
//

import SwiftUI

/// Minimal launch screen: shows Health availability and lets the user trigger
/// the HealthKit authorization sheet.
struct ContentView: View {
    private let healthKit = HealthKitService()

    @State private var statusMessage = "Not connected"
    @State private var dayCounts: [(metric: MetricKind, days: Int)] = []

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "heart.text.clipboard")
                    .font(.system(.largeTitle))
                    .foregroundStyle(.tint)
                
                Text("Insights")
                    .font(.system(.largeTitle, design: .serif))
            }

            Text(statusMessage)
                .foregroundStyle(.secondary)
            
            if HealthKitService.isAvailable {
                Button("Connect Apple Health") {
                    Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Health data isn't available on this device.")
                    .foregroundStyle(.secondary)
            }

            if !dayCounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dayCounts, id: \.metric) { entry in
                        HStack {
                            Text(entry.metric.displayName)
                            Spacer()
                            Text("\(entry.days) days")
                                .monospacedDigit()
                                .foregroundStyle(entry.days == 0 ? .secondary : .primary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding()
    
    }

    private func connect() async {
        do {
            try await healthKit.requestAuthorization()
            statusMessage = "Fetching daily aggregates…"
            await loadDayCounts()
            statusMessage = "Last 90 days, days with data per metric:"
        } catch {
            statusMessage = "Authorization failed: \(error.localizedDescription)"
        }
        // May need another way to re-trigger in the event a user does not authorise, but doesn't want to go through Settings (if this is possible; am aware Apple does not make it easy to re-trigger events after a user denies permissions)
    }

    /// Counts how many of the last 90 days have data for each metric — days
    /// without samples produce no entry, so the count exposes gaps.
    private func loadDayCounts() async {
        let aggregates = await healthKit.fetchDailyAggregates()
        dayCounts = MetricKind.allCases.map { (metric: $0, days: aggregates[$0]?.count ?? 0) }
    }
}

#Preview {
    ContentView()
}
