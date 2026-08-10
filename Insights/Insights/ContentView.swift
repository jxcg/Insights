import SwiftUI
import SwiftData

/// A window onto the cache, to prove the data underneath is right before any
/// of it gets interpreted.
///
/// On launch it shows what is already stored and touches Apple Health not at
/// all. The sync button is the only thing that does.
struct ContentView: View {
    private let healthKit = HealthKitService()

    @Environment(\.modelContext) private var modelContext

    // live views of the cache; they redraw themselves whenever a sync writes
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

    // header, sync button, and what the cache holds. Each row links through to
    // that metric's raw day-by-day table.
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

            if isShowingSampleData {
                // syncing here would pour the simulator's own Health data into
                // the invented history and leave a tester looking at both
                EmptyView()
            } else if HealthKitService.isAvailable {
                Button("Sync Apple Health") {
                    Task { await sync() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSyncing)
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
        #if DEBUG
        SampleData.isEnabled
        #else
        false
        #endif
    }

    // syncing wins over errors, errors over the cache's age. A last-synced
    // time surviving a relaunch means the cache is doing its job.
    private var status: String {
        if isShowingSampleData {
            return "Sample data — not real Health data"
        }
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

#if DEBUG
#Preview {
    ContentView()
        .modelContainer(SampleData.container())
}
#endif
