import Foundation

/// One night of sleep, summarised. The end of the sleep pipeline and the shape
/// both the engine and the screens read.
struct SleepNight {
    /// The morning's date, at midnight.
    let wakeDay: Date
    let start: Date
    let end: Date

    /// Seconds actually asleep, with overlaps already merged out.
    let asleep: TimeInterval

    /// Seconds of deep and REM sleep. nil means the night recorded no stages
    /// at all, so unknown rather than zero.
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
