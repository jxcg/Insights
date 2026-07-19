import Foundation
import HealthKit

/// A quantity metric the app reads from HealthKit, with everything needed to
/// query it and label its values.
enum MetricKind: String, CaseIterable, Identifiable {
    case heartRate
    case restingHeartRate
    case hrv
    case steps
    case activeEnergy
    case basalEnergy
    case vo2Max
    case respiratoryRate
    case wristTemperature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heartRate: "Heart rate"
        case .restingHeartRate: "Resting heart rate"
        case .hrv: "HRV (SDNN)"
        case .steps: "Steps"
        case .activeEnergy: "Active energy"
        case .basalEnergy: "Resting energy"
        case .vo2Max: "VO₂ max"
        case .respiratoryRate: "Respiratory rate"
        case .wristTemperature: "Wrist temperature"
        }
    }

    /// The HealthKit quantity type backing this metric.
    var quantityType: HKQuantityType {
        switch self {
        case .heartRate: HKQuantityType(.heartRate)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .hrv: HKQuantityType(.heartRateVariabilitySDNN)
        case .steps: HKQuantityType(.stepCount)
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .basalEnergy: HKQuantityType(.basalEnergyBurned)
        case .vo2Max: HKQuantityType(.vo2Max)
        case .respiratoryRate: HKQuantityType(.respiratoryRate)
        case .wristTemperature: HKQuantityType(.appleSleepingWristTemperature)
        }
    }

    /// How one day's samples collapse into a single value: instantaneous
    /// readings average; countable quantities sum.
    enum Aggregation {
        case average
        case sum
    }

    var aggregation: Aggregation {
        switch self {
        case .steps, .activeEnergy, .basalEnergy: .sum
        default: .average
        }
    }

    /// Unit daily values are reported in.
    var unit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate:
            HKUnit.count().unitDivided(by: .minute())
        case .hrv:
            HKUnit.secondUnit(with: .milli)
        case .steps:
            HKUnit.count()
        case .activeEnergy, .basalEnergy:
            HKUnit.kilocalorie()
        case .vo2Max:
            HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .wristTemperature:
            HKUnit.degreeCelsius()
        }
    }

    var unitLabel: String {
        switch self {
        case .heartRate, .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .steps: "steps"
        case .activeEnergy, .basalEnergy: "kcal"
        case .vo2Max: "ml/kg·min"
        case .respiratoryRate: "breaths/min"
        case .wristTemperature: "°C"
        }
    }
}
