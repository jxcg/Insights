import Foundation
import HealthKit

/// The app's single gateway to HealthKit: owns the `HKHealthStore` and the
/// set of types the app reads.
final class HealthKitService {
    private let store = HKHealthStore()

    /// False on devices without health data (e.g. iPad); callers should hide
    /// health UI entirely in that case.
    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable() 
    }

    /// Everything the app reads, requested up front in one authorization pass.
    private let readHealthTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.vo2Max),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.appleSleepingWristTemperature),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
    ]

    /// Presents the system authorization sheet on first call; later calls
    /// return without UI. HealthKit never reveals whether read access was
    /// granted — absent data is the only signal.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readHealthTypes)
    }

    /// One day's aggregated value for a metric.
    struct DailyAggregate {
        let day: Date
        let value: Double
    }

    /// Daily series for every metric over the trailing window. A metric that
    /// errors or has no samples maps to an empty series — callers treat
    /// absence as "no data", never as a failure.
    func fetchDailyAggregates(daysBack: Int = 90) async -> [MetricKind: [DailyAggregate]] {
        var seriesByKind: [MetricKind: [DailyAggregate]] = [:]
        for kind in MetricKind.allCases {
            do {
                seriesByKind[kind] = try await dailySeries(for: kind, daysBack: daysBack)
            } catch {
                seriesByKind[kind] = []
            }
        }
        return seriesByKind
    }

    /// Midnight N days back, where every trailing window query starts
    private func windowStart(daysBack: Int) -> Date? {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: .now))
    }

    /// Nights of sleep over the trailing window, oldest first
    /// however many exist is fine, one night works as well as ninety
    /// errors or no data just mean an empty list, like the daily metrics
    func fetchSleepNights(daysBack: Int = 90) async -> [SleepNight] {
        guard let windowStart = windowStart(daysBack: daysBack) else {
            return []
        }
        return await fetchSleepNights(from: windowStart)
    }

    /// Same thing from an explicit start date
    /// the sync service uses this to rebuild just the nights that changed
    func fetchSleepNights(from windowStart: Date) async -> [SleepNight] {
        let samples = (try? await fetchAsleepSamples(from: windowStart)) ?? []
        return SleepNightAggregator.nights(from: samples)
    }

    /// Pulls the last N days of sleep data as plain values
    /// only time actually asleep survives, in-bed and awake get dropped here
    /// so the rest of the app never has to think about them
    private func fetchAsleepSamples(from windowStart: Date) async throws -> [SleepSample] {
        let sortByStart = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: windowStart, end: .now),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortByStart]
            ) { _, samples, error in
                if let samples {
                    continuation.resume(returning: samples)
                } else {
                    continuation.resume(throwing: error ?? HealthKitServiceError.noResult)
                }
            }
            store.execute(query)
        }

        return samples.compactMap { sample in
            guard let category = sample as? HKCategorySample,
                  let stage = Self.asleepStage(for: category.value) else {
                return nil
            }
            return SleepSample(start: category.startDate, end: category.endDate, stage: stage)
        }
    }

    /// HealthKit's raw category number as a sleep stage, nil if it
    /// wasn't sleep at all (in bed, awake)
    private static func asleepStage(for categoryValue: Int) -> SleepSample.Stage? {
        switch HKCategoryValueSleepAnalysis(rawValue: categoryValue) {
        case .asleepUnspecified: .unspecified
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        default: nil
        }
    }

    /// What changed for one sample type since the last sync
    /// the intervals say which days need recomputing, the anchor
    /// gets saved so the next launch only asks for the delta
    struct SampleChanges {
        let newSampleIntervals: [DateInterval]
        let deletedCount: Int
        let anchorData: Data
    }

    /// Delta fetch for a quantity metric, nil anchor means first ever sync
    func fetchMetricChanges(for kind: MetricKind, since anchorData: Data?, daysBack: Int = 90) async throws -> SampleChanges {
        try await fetchChanges(for: kind.quantityType, since: anchorData, daysBack: daysBack)
    }

    /// Delta fetch for sleep, same bookmark idea as the metrics
    func fetchSleepChanges(since anchorData: Data?, daysBack: Int = 90) async throws -> SampleChanges {
        try await fetchChanges(for: HKCategoryType(.sleepAnalysis), since: anchorData, daysBack: daysBack)
    }

    /// The anchored query itself, HealthKit's "what's new since this bookmark"
    /// returns every matching sample when the anchor is nil, only the delta after
    /// deletions come back as bare ids with NO dates, callers just get a count
    private func fetchChanges(for sampleType: HKSampleType, since anchorData: Data?, daysBack: Int) async throws -> SampleChanges {
        guard let windowStart = windowStart(daysBack: daysBack) else {
            throw HealthKitServiceError.noResult
        }

        let anchor = anchorData.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }

        let (samples, deleted, newAnchor): ([HKSample], [HKDeletedObject], HKQueryAnchor) =
            try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: sampleType,
                    predicate: HKQuery.predicateForSamples(withStart: windowStart, end: nil),
                    anchor: anchor,
                    limit: HKObjectQueryNoLimit
                ) { _, samples, deleted, newAnchor, error in
                    if let samples, let newAnchor {
                        continuation.resume(returning: (samples, deleted ?? [], newAnchor))
                    } else {
                        continuation.resume(throwing: error ?? HealthKitServiceError.noResult)
                    }
                }
                store.execute(query)
            }

        return SampleChanges(
            newSampleIntervals: samples.map { DateInterval(start: $0.startDate, end: $0.endDate) },
            deletedCount: deleted.count,
            anchorData: try NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
        )
    }

    /// Runs one statistics-collection query for a metric: samples bucketed
    /// into calendar days anchored at local midnight, each day collapsed to
    /// one value per the metric's aggregation rule.
    private func dailySeries(for kind: MetricKind, daysBack: Int) async throws -> [DailyAggregate] {
        guard let windowStart = windowStart(daysBack: daysBack) else {
            return []
        }
        return try await dailySeries(for: kind, from: windowStart)
    }

    /// Same query from an explicit start
    /// the sync service recomputes changed days with this instead of the whole window
    func dailySeries(for kind: MetricKind, from windowStart: Date) async throws -> [DailyAggregate] {
        let options: HKStatisticsOptions = kind.aggregation == .sum ? .cumulativeSum : .discreteAverage
        let query = HKStatisticsCollectionQuery(
            quantityType: kind.quantityType,
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: windowStart, end: .now),
            options: options,
            anchorDate: windowStart,
            intervalComponents: DateComponents(day: 1)
        )

        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { continuation in
            query.initialResultsHandler = { _, collection, error in
                if let collection {
                    continuation.resume(returning: collection)
                } else {
                    continuation.resume(throwing: error ?? HealthKitServiceError.noResult)
                }
            }
            store.execute(query)
        }

        var series: [DailyAggregate] = []
        collection.enumerateStatistics(from: windowStart, to: .now) { statistics, _ in
            let quantity = kind.aggregation == .sum
                ? statistics.sumQuantity()
                : statistics.averageQuantity()
            if let quantity {
                series.append(DailyAggregate(
                    day: statistics.startDate,
                    value: quantity.doubleValue(for: kind.unit)
                ))
            }
        }
        return series
    }
}

/// Surfaced when HealthKit returns neither a result nor an error.
enum HealthKitServiceError: Error {
    case noResult
}
