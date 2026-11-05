import SwiftUI
import SwiftData

/// A window onto the cache, to prove the data underneath is right before any
/// of it gets interpreted. Lives in the Trends tab, and is where the metrics
/// without a Summary tile are found.
///
/// It only reads what is stored. Syncs go through the shared SyncController,
/// so this tab and the Summary never run two at once.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncController.self) private var syncController

    // live views of the cache; they redraw themselves whenever a sync writes
    @Query private var metricRecords: [DailyMetricRecord]
    @Query(sort: \SleepNightRecord.wakeDay) private var nightRecords: [SleepNightRecord]
    @Query private var anchors: [SyncAnchorRecord]

    var body: some View {
        NavigationStack {
            // nine metrics plus the extra rows outgrow a small screen
            ScrollView {
                dashboard
            }
        }
    }

    // header, sync button, and what the cache holds. Each row links through to
    // that metric's raw day-by-day table.
    private var dashboard: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "heart.text.clipboard")
                    .font(.system(.largeTitle))
                    .foregroundStyle(.tint)

                Text("Insights")
                    .font(.largeTitle)
            }

            Text(status)
                .foregroundStyle(.secondary)

            if isShowingSampleData {
                // syncing here would pour the simulator's own Health data into
                // the invented history and leave a tester looking at both
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

            if !metricRecords.isEmpty || !nightRecords.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink {
                        FindingsView()
                    } label: {
                        HStack {
                            Text("Today's findings")
                            Spacer()
                            Text("top \(rankedFindingCount)")
                                .monospacedDigit()
                                .foregroundStyle(rankedFindingCount == 0 ? .secondary : .primary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)

                    Divider()

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

    // true only on a `-sampleData` run, always false in a release build
    private var isShowingSampleData: Bool {
        SyncController.isShowingSampleData
    }

    // syncing wins over errors, errors over the cache's age. A last-synced
    // time surviving a relaunch means the cache is doing its job.
    private var status: String {
        if isShowingSampleData {
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

    // zero is a real answer here: a quiet day genuinely has nothing to say
    private var rankedFindingCount: Int {
        InsightEngine.dailyFindings(metrics: metricRecords, nights: nightRecords).count
    }

    private var dayCounts: [(metric: MetricKind, days: Int)] {
        MetricKind.allCases.map { kind in
            (metric: kind, days: metricRecords.filter { $0.metricKind == kind.rawValue }.count)
        }
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
