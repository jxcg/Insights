import Foundation

/// One chunk of sleep from Apple Health, as plain values. The service fetches
/// these and the aggregator turns them into nights. Time in bed and time awake
/// never make it this far.
struct SleepSample {
    // a watch reports core, deep or REM; older data may only say "asleep"
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
