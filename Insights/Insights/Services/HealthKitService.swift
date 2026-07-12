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
}
