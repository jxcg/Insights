import Foundation
import HealthKit

/// App's only door to Apple Health. Everything else reads the local cache, so
/// this is the one place raw health samples are ever touched.
final class HealthKitService {
    private let store = HKHealthStore()

    // false on devices with no health data at all, such as iPad; callers hide
    // the health UI entirely when this is false
    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // asked for in one go on first launch. Keep to types actually queried:
    // each is a row the user must approve.
    private let readHealthTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.vo2Max),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.appleSleepingWristTemperature),
        HKCategoryType(.sleepAnalysis),
    ]

    /// Shows the system permission sheet the first time. Later calls do nothing
    /// visible. Apple never tells us whether read access was granted, so missing
    /// data is the only signal we get.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readHealthTypes)
    }

    // midnight N days back, where every trailing-window query starts
    private func windowStart(daysBack: Int) -> Date? {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: .now))
    }

    // errors and missing data both come back as an empty list, never a failure
    func fetchSleepNights(from windowStart: Date) async -> [SleepNight] {
        let samples = (try? await fetchAsleepSamples(from: windowStart)) ?? []
        return SleepNightAggregator.nights(from: samples)
    }

    // only time actually asleep survives; in-bed and awake get dropped here,
    // so nothing downstream sees them
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

    // nil means it was not sleep at all, so in bed or awake
    private static func asleepStage(for categoryValue: Int) -> SleepSample.Stage? {
        switch HKCategoryValueSleepAnalysis(rawValue: categoryValue) {
        case .asleepUnspecified: .unspecified
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        default: nil
        }
    }

    // intervals say which days need recomputing. Anchor is the bookmark to
    // hand back next time, so we only ask for what is new.
    struct SampleChanges {
        let newSampleIntervals: [DateInterval]
        let deletedCount: Int
        let anchorData: Data
    }

    // a nil anchor means we have never synced this metric
    func fetchMetricChanges(for kind: MetricKind, since anchorData: Data?, daysBack: Int = 90) async throws -> SampleChanges {
        try await fetchChanges(for: kind.quantityType, since: anchorData, daysBack: daysBack)
    }

    // same bookmark idea as the metrics
    func fetchSleepChanges(since anchorData: Data?, daysBack: Int = 90) async throws -> SampleChanges {
        try await fetchChanges(for: HKCategoryType(.sleepAnalysis), since: anchorData, daysBack: daysBack)
    }

    // Apple's "what is new since this bookmark" query. With no bookmark it
    // returns everything, after that only the changes. Deletions come back as
    // bare ids with no dates attached, so callers only ever get a count.
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

    /// One metric's samples bucketed into calendar days, each day collapsed to
    /// one number by that metric's own rule: steps add up, heart rate averages.
    func dailySeries(for kind: MetricKind, from windowStart: Date) async throws -> [DatedValue] {
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

        var series: [DatedValue] = []
        collection.enumerateStatistics(from: windowStart, to: .now) { statistics, _ in
            let quantity = kind.aggregation == .sum
                ? statistics.sumQuantity()
                : statistics.averageQuantity()
            if let quantity {
                series.append(DatedValue(
                    day: statistics.startDate,
                    value: quantity.doubleValue(for: kind.unit)
                ))
            }
        }
        return series
    }
}

// thrown when Apple Health hands back neither a result nor an error
enum HealthKitServiceError: Error {
    case noResult
}
