import Foundation
import SwiftData

/// A SleepNight saved to disk so relaunches read from here, not HealthKit
/// the sync service writes these, the UI and analytics read them
@Model
final class SleepNightRecord {
    var wakeDay: Date
    var start: Date
    var end: Date
    var asleep: TimeInterval

    /// nil means the night's data had no stages, UNKNOWN not zero
    var deep: TimeInterval?
    var rem: TimeInterval?

    init(night: SleepNight) {
        wakeDay = night.wakeDay
        start = night.start
        end = night.end
        asleep = night.asleep
        deep = night.deep
        rem = night.rem
    }

    /// Back to the plain value type the rest of the app works with
    var night: SleepNight {
        SleepNight(wakeDay: wakeDay, start: start, end: end, asleep: asleep, deep: deep, rem: rem)
    }
}
