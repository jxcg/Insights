import SwiftData
import SwiftUI

/// The designed home screen (FINAL-PLAN §1 and §4): readiness, the four
/// metric tiles, the day's insights, and the week.
///
/// One view set for both recovery states. `RecoveryState` alone shifts the
/// aurora, the hero wording and which tiles get the attention treatment.
///
/// It decides nothing itself. Everything shown comes from a `DailySnapshot`,
/// built once from template sentences so the screen fills instantly; when
/// on-device narration finishes, only its insights are swapped. If narration
/// never finishes, the templates simply stay.
struct SummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncController.self) private var syncController

    @Query private var metricRecords: [DailyMetricRecord]
    @Query(sort: \SleepNightRecord.wakeDay) private var nightRecords: [SleepNightRecord]
    @Query private var anchors: [SyncAnchorRecord]

    @State private var snapshot: DailySnapshot?

    // the last narration, reused while the findings are unchanged, so coming
    // back to the tab never flips the wording back to the template
    @State private var lastNarrated: DailyDigest?

    // bumped each time the app comes back to the foreground, so an app left
    // open overnight rebuilds for the new morning
    @State private var activations = 0

    private var lastSynced: Date? { anchors.map(\.lastSynced).max() }

    // what the snapshot depends on. A sync always moves lastSynced, even when
    // it replaced records without changing their count.
    private struct DataVersion: Equatable {
        let metricCount: Int
        let nightCount: Int
        let lastSynced: Date?
        let activations: Int
        let isSyncing: Bool
    }

    private var dataVersion: DataVersion {
        DataVersion(
            metricCount: metricRecords.count, nightCount: nightRecords.count,
            lastSynced: lastSynced, activations: activations,
            isSyncing: syncController.isSyncing)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(state: snapshot?.recoveryState ?? .recovered)
                content
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.large)
        }
        .task(id: dataVersion) {
            await refresh()
        }
        .task {
            await syncController.syncIfStale(context: modelContext, lastSynced: lastSynced)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            activations += 1
            Task { await syncController.syncIfStale(context: modelContext, lastSynced: lastSynced) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if snapshot == nil {
            // the first frame, before the cache has been read: nothing yet,
            // rather than a misleading "no data"
            Color.clear
        } else if let snapshot, snapshot.hasAnyData {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    if let status = statusLine {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(statusIsWarning ? Theme.amberText : Theme.bodySecondary)
                    }
                    ReadinessHero(snapshot: snapshot)
                    MetricGrid(tiles: snapshot.tiles)
                    InsightsStack(insights: snapshot.insights)
                    WeekReadinessChart(week: snapshot.weekReadiness)
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)
                .padding(.bottom, Theme.Spacing.section)
            }
            .refreshable {
                await syncController.sync(context: modelContext)
            }
        } else {
            EmptySummary(
                isSyncing: syncController.isSyncing,
                hasSyncedBefore: lastSynced != nil,
                errorMessage: syncController.errorMessage,
                retry: { Task { await syncController.sync(context: modelContext) } })
        }
    }

    // sample data, a running sync or a failed permission request, said once
    // above the hero; nothing when all is normal
    private var statusLine: String? {
        if SyncController.isShowingSampleData { return "Sample data — not your Health data" }
        if syncController.isSyncing { return "Syncing with Apple Health…" }
        return syncController.errorMessage
    }

    private var statusIsWarning: Bool {
        SyncController.isShowingSampleData || syncController.errorMessage != nil
    }

    // template snapshot first, narrated one after. A newer data version
    // cancels this task, and the generator then stops narrating. A sync
    // writes many records one by one, so nothing is rebuilt until it ends;
    // its end changes the data version and triggers one rebuild.
    private func refresh() async {
        // the very first build still runs mid-sync, so the screen is never
        // left blank while a sync that started first is still going
        guard !syncController.isSyncing || snapshot == nil else { return }

        // the stored records are read once; everything below works on copies
        let history = HealthHistory(metrics: metricRecords, nights: nightRecords)
        let findings = InsightEngine.dailyFindings(history: history)
        // both texts: a trend's latest value is only in `meaning`, and a
        // narrated sentence may quote it
        let wording = findings.map { $0.plainStatement + $0.meaning }

        let reuse = lastNarrated.flatMap { cached in
            cached.insights.map { $0.finding.plainStatement + $0.finding.meaning } == wording ? cached : nil
        }
        snapshot = SnapshotBuilder.build(
            history: history,
            digest: reuse ?? InsightGenerator.templateDigest(for: findings),
            lastSynced: lastSynced)

        guard reuse == nil, !findings.isEmpty else { return }
        let narrated = await InsightGenerator.live().narrate(findings)
        guard !Task.isCancelled else { return }
        lastNarrated = narrated
        // only the sentences change; tiles, readiness and the week stay as built
        snapshot?.insights = narrated.insights.map(SnapshotBuilder.insight)
    }
}

// MARK: Readiness hero

/// The frosted card the aurora glows through: headline, score, delta, and
/// what the score is made of.
private struct ReadinessHero: View {
    let snapshot: DailySnapshot

    private var copy: HeroCopy.Copy { HeroCopy.copy(for: snapshot.readiness) }
    private var isLow: Bool { snapshot.recoveryState == .lowRecovery }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            Text(copy.headline)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)

            if let readiness = snapshot.readiness {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(readiness.score)")
                        .font(.system(size: Theme.Size.heroScore, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                        .accessibilityLabel("Readiness \(readiness.score) out of 100")
                    if let delta = HeroCopy.delta(readiness.delta) {
                        Text(delta)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(deltaColor(readiness.delta))
                    }
                }
            }

            Text(copy.explanation)
                .font(.callout)
                .foregroundStyle(Theme.bodyPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // provisional and stale data are said plainly, never hidden
            if snapshot.provisional.lastNightStillSettling {
                Text("Last night is still syncing, so sleep joins the score once it settles.")
                    .font(.footnote)
                    .foregroundStyle(Theme.bodySecondary)
            }
            if !snapshot.syncFresh, let lastSynced = snapshot.lastSynced {
                Text("Last synced \(lastSynced.formatted(.relative(presentation: .named))).")
                    .font(.footnote)
                    .foregroundStyle(Theme.bodySecondary)
            }
        }
        .padding(Theme.Spacing.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.border.opacity(0.7), lineWidth: Theme.hairline))
        .accessibilityElement(children: .combine)
    }

    // up reads positive; down reads amber, never red
    private func deltaColor(_ delta: Int?) -> Color {
        guard let delta, delta != 0 else { return Theme.bodySecondary }
        return delta > 0 ? Theme.positive : Theme.amberText
    }
}

// MARK: Metric grid

private struct MetricGrid: View {
    let tiles: [MetricTile]

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.gridGap),
        GridItem(.flexible(), spacing: Theme.Spacing.gridGap),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.gridGap) {
            ForEach(tiles, id: \.metric) { tile in
                MetricTileView(tile: tile)
            }
        }
    }
}

// MARK: Insights

private struct InsightsStack: View {
    let insights: [Insight]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            Text("Insights")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)

            if insights.isEmpty {
                // a quiet day genuinely has nothing to say
                Text("Nothing stands out today. Everything sits within your usual range.")
                    .font(.callout)
                    .foregroundStyle(Theme.bodySecondary)
            } else {
                ForEach(Array(insights.enumerated()), id: \.offset) { index, insight in
                    InsightRowView(insight: insight, isLead: index == 0)
                }
            }
        }
    }
}

// MARK: Week chart

/// Seven mornings as bars, today's in the accent gradient. A morning with no
/// score keeps its place as a faint stub.
private struct WeekReadinessChart: View {
    let week: [DayReadiness]

    private let chartHeight = Theme.Size.weekChart

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            Text("Readiness this week")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                    let isToday = index == week.count - 1
                    VStack(spacing: 6) {
                        bar(score: day.score, isToday: isToday)
                            // every column the same height, so labels line up
                            // and grow freely with Dynamic Type
                            .frame(height: chartHeight, alignment: .bottom)
                        Text(day.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2)
                            .foregroundStyle(isToday ? Theme.ink : Theme.bodySecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText(for: day))
                }
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline))
    }

    @ViewBuilder
    private func bar(score: Int?, isToday: Bool) -> some View {
        let height = score.map { max(CGFloat($0) / 100 * chartHeight, 4) } ?? 4
        if isToday {
            Capsule().fill(Theme.todayBarGradient).frame(height: height)
        } else {
            // a morning with no score is just a stub in the border colour
            Capsule()
                // grey past bars clear the 3:1 minimum for a graphic and
                // leave today's purple as the only colour in the chart
                .fill(score == nil ? AnyShapeStyle(Theme.border) : AnyShapeStyle(Theme.bodySecondary))
                .frame(height: height)
        }
    }

    private func accessibilityText(for day: DayReadiness) -> String {
        let weekday = day.day.formatted(.dateTime.weekday(.wide))
        guard let score = day.score else { return "\(weekday), no score" }
        return "\(weekday), \(score)"
    }
}

// MARK: Empty, loading and no-permission states

/// Shown while the cache holds nothing at all.
private struct EmptySummary: View {
    let isSyncing: Bool
    let hasSyncedBefore: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.rowGap) {
            if isSyncing {
                ProgressView()
                Text("Reading Apple Health…")
                    .foregroundStyle(Theme.bodySecondary)
            } else if !SyncController.canSync {
                Text(SyncController.isShowingSampleData
                     ? "Sample data is on, but nothing was generated."
                     : "Health data is not available on this device.")
                    .foregroundStyle(Theme.bodySecondary)
            } else {
                Text(hasSyncedBefore ? "No Health data yet" : "Connect Apple Health")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(Theme.bodySecondary)
                    .multilineTextAlignment(.center)
                Button(hasSyncedBefore ? "Try again" : "Connect", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .padding(.top, Theme.Spacing.tight)
            }
        }
        .padding(Theme.Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Apple never says whether read access was granted, so an empty sync is
    // the only sign it was not
    private var explanation: String {
        if let errorMessage { return errorMessage }
        if hasSyncedBefore {
            return "Apple Health returned nothing. If you didn't allow access, turn it on in "
                + "Settings › Privacy & Security › Health › Insights, then try again."
        }
        return "Insights reads your sleep, heart and activity data to show how you compare "
            + "with your own normal. Nothing leaves this device."
    }
}

#if DEBUG
#Preview {
    SummaryView()
        .environment(SyncController())
        .modelContainer(SampleData.container())
}
#endif
