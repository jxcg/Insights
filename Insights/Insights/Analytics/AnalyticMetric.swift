import Foundation

/// Every series the engine can judge: the quantity metrics read from Apple
/// Health, plus the nightly durations derived from sleep. Sleep is in hours.
enum AnalyticMetric: Hashable {
    case quantity(MetricKind)
    case sleepDuration
    case deepSleepDuration
    case remSleepDuration

    var displayName: String {
        switch self {
        case .quantity(let kind): kind.displayName
        case .sleepDuration: "Sleep duration"
        case .deepSleepDuration: "Deep sleep"
        case .remSleepDuration: "REM sleep"
        }
    }

    var unitLabel: String {
        switch self {
        case .quantity(let kind): kind.unitLabel
        case .sleepDuration, .deepSleepDuration, .remSleepDuration: "h"
        }
    }

    /// The last day this metric can fairly be judged on. A quantity stops at
    /// yesterday, because today is still adding to itself; sleep counts today,
    /// because a night is filed under the morning it ended.
    func latestCompleteDay(asOf now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .quantity:
            return calendar.date(byAdding: .day, value: -1, to: today)
        case .sleepDuration, .deepSleepDuration, .remSleepDuration:
            return today
        }
    }

    /// A value written the way findings quote it — "72 bpm", "7.5 h". Whole
    /// numbers stay whole, everything else gets one decimal.
    func formattedWithUnit(_ value: Double) -> String {
        let number = value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
        return "\(number) \(unitLabel)"
    }
}
