import Foundation

/// Every series the analytics engine works over: the cached quantity metrics
/// plus the nightly durations derived from sleep. Sleep values are in hours.
enum AnalyticMetric: Hashable {
    case quantity(MetricKind)
    case sleepDuration
    case deepSleepDuration
    case remSleepDuration

    /// Every metric the engine attempts baselines for.
    static var all: [AnalyticMetric] {
        MetricKind.allCases.map { .quantity($0) }
            + [.sleepDuration, .deepSleepDuration, .remSleepDuration]
    }

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
}
