import Foundation
import SwiftData

/// Keeps the local cache in step with HealthKit
/// asks each type what changed, recomputes just those days, saves the anchor
/// first ever run has no anchor so everything counts as changed, same code path
/// the UI reads SwiftData only, this is the ONE place that writes it
@MainActor
final class SyncService {
    private let healthKit: HealthKitService
    private let context: ModelContext
    private let calendar = Calendar.current

    /// Days of history the cache keeps, a ceiling not a floor
    private let windowDays = 90

    /// Anchor key for sleep, metrics use their MetricKind rawValue
    private let sleepKey = "sleep"

    init(healthKit: HealthKitService, context: ModelContext) {
        self.healthKit = healthKit
        self.context = context
    }

    /// One pass over every metric plus sleep
    /// a failing type just keeps its old anchor and retries next launch
    func sync() async {
        for kind in MetricKind.allCases {
            try? await syncMetric(kind)
        }
        try? await syncSleep()
        prune()
        try? context.save()
    }

    /// Delta sync for one metric
    /// records are replaced BEFORE the anchor moves, so a crash mid-sync
    /// just means the same delta gets reported again next launch
    private func syncMetric(_ kind: MetricKind) async throws {
        let existing = anchorRecord(for: kind.rawValue)
        let changes = try await healthKit.fetchMetricChanges(
            for: kind, since: existing?.anchorData, daysBack: windowDays)

        if let start = recomputeStart(for: changes) {
            let series = try await healthKit.dailySeries(for: kind, from: start)
            replaceMetricRecords(for: kind, from: start, with: series)
            print("sync \(kind.rawValue): recomputed \(series.count) days from \(start.formatted(date: .abbreviated, time: .omitted))")
        } else {
            print("sync \(kind.rawValue): no changes")
        }
        saveAnchor(changes.anchorData, for: kind.rawValue, existing: existing)
    }

    /// Delta sync for sleep
    /// rebuilds nights from the day before the earliest change, a night's
    /// samples can start the previous evening so the lead-in keeps sessions whole
    private func syncSleep() async throws {
        let existing = anchorRecord(for: sleepKey)
        let changes = try await healthKit.fetchSleepChanges(
            since: existing?.anchorData, daysBack: windowDays)

        if let start = recomputeStart(for: changes),
           let leadIn = calendar.date(byAdding: .day, value: -1, to: start) {
            let nights = await healthKit.fetchSleepNights(from: leadIn)
                .filter { $0.wakeDay >= start }
            replaceNightRecords(from: start, with: nights)
            print("sync sleep: recomputed \(nights.count) nights from \(start.formatted(date: .abbreviated, time: .omitted))")
        } else {
            print("sync sleep: no changes")
        }
        saveAnchor(changes.anchorData, for: sleepKey, existing: existing)
    }

    /// The day recomputation starts from, nil means nothing changed at all
    /// deletions come with no dates, so they redo the last two days as a net
    /// deleting older history than that needs a full resync to show up
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

    /// Swaps cached days from a start date for freshly computed ones
    /// delete then insert, so a day that lost all its data disappears properly
    private func replaceMetricRecords(for kind: MetricKind, from start: Date, with series: [HealthKitService.DailyAggregate]) {
        let key = kind.rawValue
        let stale = FetchDescriptor<DailyMetricRecord>(
            predicate: #Predicate { $0.metricKind == key && $0.date >= start })
        for record in (try? context.fetch(stale)) ?? [] {
            context.delete(record)
        }
        for aggregate in series {
            context.insert(DailyMetricRecord(
                date: aggregate.day, metricKind: key, value: aggregate.value, unit: kind.unitLabel))
        }
    }

    /// Same swap for sleep nights, keyed on the morning they end
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

    /// The bookmark only ever moves after the records it covers are in place
    private func saveAnchor(_ data: Data, for key: String, existing: SyncAnchorRecord?) {
        if let existing {
            existing.anchorData = data
            existing.lastSynced = .now
        } else {
            context.insert(SyncAnchorRecord(typeKey: key, anchorData: data, lastSynced: .now))
        }
    }

    /// Drops cached days that have slid out of the trailing window
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
