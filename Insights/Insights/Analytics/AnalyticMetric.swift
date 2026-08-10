import Foundation

/// Everything the engine can analyse: numbers from Apple Health, plus three
/// sleep durations derived from sleep samples. Sleep is in hours.
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

    /// Last day worth judging this metric on.
    ///
    /// Steps stop at yesterday: today is still counting up, so it always looks
    /// low. Sleep can use today, since last night files under this morning.
    func latestCompleteDay(asOf now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .quantity:
            return calendar.date(byAdding: .day, value: -1, to: today) ?? today
        case .sleepDuration, .deepSleepDuration, .remSleepDuration:
            return today
        }
    }

    /// Good news, bad news, or just news. Set in Swift so AI can't narrate a
    /// warning sign cheerfully.
    ///
    /// `sustained` is true for a weeks-long trend, false for one odd day.
    /// Only changes activity: steps sliding for weeks earns a caution, one
    /// quiet day does not.
    func tone(direction: Finding.Direction, sustained: Bool) -> Finding.Tone {
        switch self {
        case .quantity(let kind):
            switch kind {
            case .heartRate, .restingHeartRate, .respiratoryRate, .wristTemperature:
                return direction == .rising ? .cautionary : .neutral
            case .hrv, .vo2Max:
                return direction == .falling ? .cautionary : .positive
            case .steps, .activeEnergy:
                if direction == .rising { return .positive }
                return sustained ? .cautionary : .neutral
            case .basalEnergy:
                return .neutral
            }
        case .sleepDuration, .deepSleepDuration, .remSleepDuration:
            return direction == .falling ? .cautionary : .neutral
        }
    }

    /// Formats values the way findings quote them: "72 bpm", "7.5 h".
    /// Whole numbers stay whole, rest get one decimal.
    func formattedWithUnit(_ value: Double) -> String {
        let number = value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
        return "\(number) \(unitLabel)"
    }
}
