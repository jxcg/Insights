import Foundation
import SwiftData

/// Keeps the local cache in step with Apple Health.
///
/// Asks each type what changed, rebuilds only those days, saves the bookmark.
/// First run has no bookmark, so everything counts as changed and takes the
/// same code path.
///
/// Everything else in the app reads the cache. This is the only thing that
/// writes it.
@MainActor
final class SyncService {
    private let healthKit: HealthKitService
    private let context: ModelContext
    private let calendar = Calendar.current

    /// Days of history the cache keeps. A ceiling, not a floor: the engine
    /// works with far less than this.
    private let windowDays = 90

    /// Bookmark key for sleep. Metrics use their own MetricKind name.
    private let sleepKey = "sleep"

    init(healthKit: HealthKitService, context: ModelContext) {
        self.healthKit = healthKit
        self.context = context
    }

    /// One pass over every metric, then sleep. A type that fails keeps its old
    /// bookmark and tries again next launch.
    func sync() async {
        for kind in MetricKind.allCases {
            try? await syncMetric(kind)
        }
        try? await syncSleep()
        prune()
        try? context.save()
    }

    /// Brings one metric up to date. Records get replaced before the bookmark
    /// moves, so a crash halfway just means the same changes get reported
    /// again next launch.
    private func syncMetric(_ kind: MetricKind) async throws {
        let existing = anchorRecord(for: kind.rawValue)
        let changes = try await healthKit.fetchMetricChanges(
            for: kind, since: existing?.anchorData, daysBack: windowDays)

        if let start = recomputeStart(for: changes) {
            let series = try await healthKit.dailySeries(for: kind, from: start)
            replaceMetricRecords(for: kind, from: start, with: series)
        }
        saveAnchor(changes.anchorData, for: kind.rawValue, existing: existing)
    }

    /// Brings sleep up to date. Nights are rebuilt from the day before the
    /// earliest change: a night's samples can start the previous evening, and
    /// that extra day keeps sessions whole.
    private func syncSleep() async throws {
        let existing = anchorRecord(for: sleepKey)
        let changes = try await healthKit.fetchSleepChanges(
            since: existing?.anchorData, daysBack: windowDays)

        if let start = recomputeStart(for: changes),
           let leadIn = calendar.date(byAdding: .day, value: -1, to: start) {
            let nights = await healthKit.fetchSleepNights(from: leadIn)
                .filter { $0.wakeDay >= start }
            replaceNightRecords(from: start, with: nights)
        }
        saveAnchor(changes.anchorData, for: sleepKey, existing: existing)
    }

    /// Which day to rebuild from. nil means nothing changed at all.
    ///
    /// Deletions arrive without dates, so they cast a net over the last two
    /// days. Deleting anything older than that needs a full resync to show up.
    private func recomputeStart(for changes: HealthKitService.SampleChanges) -> Date? {
        var start: Date?
        if let earliestNew = changes.newSampleIntervals.map(\.start).min() {
            start = calendar.startOfDay(for: earliestNew)
        }
        if changes.deletedCount > 0,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now)) {
            start = min(start ?? yesterday, yesterday)
        }
        return start
    }

    /// Swaps cached days from a start date for freshly computed ones.
    /// Delete then insert, so a day that lost all its data actually goes.
    private func replaceMetricRecords(for kind: MetricKind, from start: Date, with series: [DatedValue]) {
        let key = kind.rawValue
        let stale = FetchDescriptor<DailyMetricRecord>(
            predicate: #Predicate { $0.metricKind == key && $0.date >= start })
        for record in (try? context.fetch(stale)) ?? [] {
            context.delete(record)
        }
        for dated in series {
            context.insert(DailyMetricRecord(
                date: dated.day, metricKind: key, value: dated.value, unit: kind.unitLabel))
        }
    }

    /// The same swap for sleep nights, filed under the morning they ended.
    private func replaceNightRecords(from start: Date, with nights: [SleepNight]) {
        let stale = FetchDescriptor<SleepNightRecord>(
            predicate: #Predicate { $0.wakeDay >= start })
        for record in (try? context.fetch(stale)) ?? [] {
            context.delete(record)
        }
        for night in nights {
            context.insert(SleepNightRecord(night: night))
        }
    }

    private func anchorRecord(for key: String) -> SyncAnchorRecord? {
        let descriptor = FetchDescriptor<SyncAnchorRecord>(
            predicate: #Predicate { $0.typeKey == key })
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    /// The bookmark only ever moves once the records it covers are safely in.
    private func saveAnchor(_ data: Data, for key: String, existing: SyncAnchorRecord?) {
        if let existing {
            existing.anchorData = data
            existing.lastSynced = .now
        } else {
            context.insert(SyncAnchorRecord(typeKey: key, anchorData: data, lastSynced: .now))
        }
    }

    /// Drops cached days that have slid out the back of the window.
    private func prune() {
        guard let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: calendar.startOfDay(for: .now)) else {
            return
        }
        let oldMetrics = FetchDescriptor<DailyMetricRecord>(
            predicate: #Predicate { $0.date < cutoff })
        for record in (try? context.fetch(oldMetrics)) ?? [] {
            context.delete(record)
        }
        let oldNights = FetchDescriptor<SleepNightRecord>(
            predicate: #Predicate { $0.wakeDay < cutoff })
        for record in (try? context.fetch(oldNights)) ?? [] {
            context.delete(record)
        }
    }
}
