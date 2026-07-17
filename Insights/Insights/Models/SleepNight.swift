import Foundation

/// One night of sleep, summarised and ready to use
/// this is the end product of the sleep pipeline and the shape
/// the analytics engine and UI will read
struct SleepNight {
    /// The morning's date, midnight-anchored
    let wakeDay: Date
    let start: Date
    let end: Date

    /// Seconds actually asleep, overlaps already merged out
    let asleep: TimeInterval

    /// Seconds of deep and rem sleep, nil when the night's data
    /// never recorded stages so we can't know
    let deep: TimeInterval?
    let rem: TimeInterval?

    var deepPercent: Double? { percentOfNight(deep) }
    var remPercent: Double? { percentOfNight(rem) }

    var asleepHours: Double { asleep / 3600 }

    private func percentOfNight(_ stage: TimeInterval?) -> Double? {
        guard let stage, asleep > 0 else { return nil }
        return stage / asleep * 100
    }
}
