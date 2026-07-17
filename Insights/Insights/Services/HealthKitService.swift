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
    private let readTypes: Set<HKObjectType> = [
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
        try await store.requestAuthorization(toShare: [], read: readTypes)
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

    /// Runs one statistics-collection query for a metric: samples bucketed
    /// into calendar days anchored at local midnight, each day collapsed to
    /// one value per the metric's aggregation rule.
    private func dailySeries(for kind: MetricKind, daysBack: Int) async throws -> [DailyAggregate] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let windowStart = calendar.date(byAdding: .day, value: -daysBack, to: today) else {
            return []
        }

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
