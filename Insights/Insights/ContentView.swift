import SwiftUI
import SwiftData

/// The Trends tab: a window onto the cache, raw, including the metrics without
/// a Summary tile. Each row opens that metric's day-by-day table, so numbers
/// can be checked against the Health app.
///
/// Syncs go through the shared SyncController, so this tab and the Summary
/// never run two at once.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncController.self) private var syncController

    // live views of the cache; they redraw themselves whenever a sync writes
    @Query private var metricRecords: [DailyMetricRecord]
    @Query(sort: \SleepNightRecord.wakeDay) private var nightRecords: [SleepNightRecord]
    @Query private var anchors: [SyncAnchorRecord]

    // worked out when the cache changes, never inside body; nil until then
    @State private var rankedFindingCount: Int?

    var body: some View {
        // one pass over the records per redraw, not one per metric
        let daysByKind = metricRecords.reduce(into: [String: Int]()) { $0[$1.metricKind, default: 0] += 1 }

        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "heart.text.clipboard")
                            .font(.system(.largeTitle))
                            .foregroundStyle(.tint)
                        Text("Insights")
                            .font(.largeTitle)
                    }
                    Text(status)
                        .foregroundStyle(.secondary)
                    if SyncController.isShowingSampleData {
                        // syncing here would pour the simulator's own Health
                        // data into the invented history
                        EmptyView()
                    } else if HealthKitService.isAvailable {
                        Button("Sync Apple Health") {
                            Task { await syncController.sync(context: modelContext) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncController.isSyncing)
                    } else {
                        Text("Health data is not available from this device.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !metricRecords.isEmpty || !nightRecords.isEmpty {
                    Section {
                        // zero is a real answer: a quiet day has nothing to say
                        row("Today's findings",
                            detail: rankedFindingCount.map { "top \($0)" } ?? "top …",
                            isZero: rankedFindingCount == 0) { FindingsView() }
                    }
                    Section {
                        ForEach(MetricKind.allCases) { kind in
                            let days = daysByKind[kind.rawValue] ?? 0
                            row(kind.displayName, detail: "\(days) days", isZero: days == 0) {
                                MetricDetailView(kind: kind)
                            }
                        }
                        let energyDays = totalEnergyDays
                        row("Total energy", detail: "\(energyDays) days", isZero: energyDays == 0) {
                            TotalEnergyView()
                        }
                        row("Sleep nights", detail: sleepSummary) { SleepNightsView() }
                    }
                }
            }
        }
        // a sync can replace records without changing their count, so the
        // last sync time is part of what is watched
        .task(id: [
            Double(metricRecords.count), Double(nightRecords.count),
            anchors.map(\.lastSynced).max()?.timeIntervalSince1970 ?? 0,
        ]) {
            rankedFindingCount = InsightEngine.dailyFindings(metrics: metricRecords, nights: nightRecords).count
        }
    }

    // a zero count reads quieter, as it always has
    private func row<Destination: View>(
        _ title: String,
        detail: String,
        isZero: Bool = false,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
                    .monospacedDigit()
                    .foregroundStyle(isZero ? .secondary : .primary)
            }
            .font(.callout)
        }
    }

    // syncing wins over errors, errors over the cache's age. A last-synced
    // time surviving a relaunch means the cache is doing its job.
    private var status: String {
        if SyncController.isShowingSampleData {
            return "Sample data — not real Health data"
        }
        if syncController.isSyncing {
            return "Syncing…"
        }
        if let errorMessage = syncController.errorMessage {
            return errorMessage
        }
        if let lastSynced = anchors.map(\.lastSynced).max() {
            return "Last synced \(lastSynced.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Not connected"
    }

    // days complete enough to have earned a total, the same join the detail
    // screen shows
    private var totalEnergyDays: Int {
        TotalEnergy.dailyTotals(
            active: metricRecords.filter { $0.metricKind == MetricKind.activeEnergy.rawValue },
            basal: metricRecords.filter { $0.metricKind == MetricKind.basalEnergy.rawValue }
        ).filter(\.hasCompleteEnergyRecord).count
    }

    // one line to eyeball against the Health app: how many nights, plus the
    // most recent one
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
}

#if DEBUG
#Preview {
    ContentView()
        .environment(SyncController())
        .modelContainer(SampleData.container())
}
#endif
