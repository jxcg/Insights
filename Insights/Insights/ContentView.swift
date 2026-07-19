//
//  ContentView.swift
//  Insights
//
//  Created by Joshua Ng on 11/07/2026.
//

import SwiftUI
import SwiftData

/// Verification screen over the cache
/// on launch it shows whatever SwiftData has, no HealthKit calls at all
/// the sync button is the ONLY thing that talks to HealthKit
struct ContentView: View {
    private let healthKit = HealthKitService()

    @Environment(\.modelContext) private var modelContext

    /// Live views of the cache, they refresh themselves when a sync writes
    @Query private var metricRecords: [DailyMetricRecord]
    @Query(sort: \SleepNightRecord.wakeDay) private var nightRecords: [SleepNightRecord]
    @Query private var anchors: [SyncAnchorRecord]

    @State private var errorMessage: String?
    @State private var isSyncing = false

    var body: some View {
        NavigationStack {
            dashboard
        }
    }

    /// The summary screen itself, header plus sync plus cache overview
    /// each metric row links through to its raw day by day table
    private var dashboard: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "heart.text.clipboard")
                    .font(.system(.largeTitle))
                    .foregroundStyle(.tint)

                Text("Insights")
                    .font(.system(.largeTitle, design: .serif))
            }

            Text(status)
                .foregroundStyle(.secondary)

            if HealthKitService.isAvailable {
                Button("Sync Apple Health") {
                    Task { await sync() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSyncing)
            } else {
                Text("Health data isn't available on this device.")
                    .foregroundStyle(.secondary)
            }

            if !metricRecords.isEmpty || !nightRecords.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dayCounts, id: \.metric) { entry in
                        NavigationLink {
                            MetricDetailView(kind: entry.metric)
                        } label: {
                            HStack {
                                Text(entry.metric.displayName)
                                Spacer()
                                Text("\(entry.days) days")
                                    .monospacedDigit()
                                    .foregroundStyle(entry.days == 0 ? .secondary : .primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink {
                        TotalEnergyView()
                    } label: {
                        HStack {
                            Text("Total energy")
                            Spacer()
                            Text("\(totalEnergyDays) days")
                                .monospacedDigit()
                                .foregroundStyle(totalEnergyDays == 0 ? .secondary : .primary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        SleepNightsView()
                    } label: {
                        HStack {
                            Text("Sleep nights")
                            Spacer()
                            Text(sleepSummary)
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
        }
        .padding()
    }

    /// What the status line says, syncing beats errors beats cache age
    /// a last-synced time surviving relaunch is the cache working
    private var status: String {
        if isSyncing {
            return "Syncing…"
        }
        if let errorMessage {
            return errorMessage
        }
        if let lastSynced = anchors.map(\.lastSynced).max() {
            return "Last synced \(lastSynced.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Not connected"
    }

    /// Days with data per metric, straight from the cache
    private var dayCounts: [(metric: MetricKind, days: Int)] {
        MetricKind.allCases.map { kind in
            (metric: kind, days: metricRecords.filter { $0.metricKind == kind.rawValue }.count)
        }
    }

    /// Complete days that earned a derived total, same join the detail screen shows
    private var totalEnergyDays: Int {
        TotalEnergy.dailyTotals(
            active: metricRecords.filter { $0.metricKind == MetricKind.activeEnergy.rawValue },
            basal: metricRecords.filter { $0.metricKind == MetricKind.basalEnergy.rawValue }
        ).filter(\.hasCompleteEnergyRecord).count
    }

    /// One line to eyeball against the Health app, count plus the latest night
    private var sleepSummary: String {
        guard let latest = nightRecords.last?.night else {
            return "Not Available"
        }
        var summary = "\(nightRecords.count) · last \(String(format: "%.1f", latest.asleepHours))h"
        if let deep = latest.deepPercent, let rem = latest.remPercent {
            summary += " · deep \(Int(deep))% rem \(Int(rem))%"
        }
        return summary
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await healthKit.requestAuthorization()
            await SyncService(healthKit: healthKit, context: modelContext).sync()
            errorMessage = nil
        } catch {
            errorMessage = "Authorisation failed: \(error.localizedDescription)"
        }
        // May need another way to re-trigger in the event a user does not authorise, but doesn't want to go through Settings (if this is possible; am aware Apple does not make it easy to re-trigger events after a user denies permissions)
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [DailyMetricRecord.self, SleepNightRecord.self, SyncAnchorRecord.self],
            inMemory: true
        )
}
