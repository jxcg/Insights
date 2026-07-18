import Foundation

/// One chunk of sleep from HealthKit as plain values
/// the service fetches these, the aggregator turns them into nights
/// in-bed and awake time NEVER makes it this far
struct SleepSample {
    /// What kind of sleep, watches give core/deep/rem
    /// older data may just say unspecified
    enum Stage {
        case unspecified
        case core
        case deep
        case rem
    }

    let start: Date
    let end: Date
    let stage: Stage
}
