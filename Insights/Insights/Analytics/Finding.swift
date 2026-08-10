import Foundation

/// One thing worth telling the user. All judging already done.
///
/// Swift decides what moved, which way, whether it matters. AI only rewords
/// it. AI never decides what numbers mean.
struct Finding {
    enum FindingType: String {
        case anomaly
        case trend
        case correlation
    }

    /// Movement only. Good or bad is `tone`.
    enum Direction: String {
        case rising
        case falling
        case steady
    }

    /// Set in Swift so AI can't narrate a warning sign cheerfully.
    enum Tone: String {
        case positive
        case neutral
        case cautionary
    }

    let type: FindingType

    // for a correlation, `metric` is the outcome the user cares about and
    // `drivingMetric` the thing moving it; nil for single-metric findings
    let metric: AnalyticMetric
    let drivingMetric: AnalyticMetric?

    /// How big the effect is, in each detector's own units: standard
    /// deviations for an anomaly, percent for a trend, r for a correlation.
    /// `FindingRanker` converts these onto one scale.
    let magnitude: Double

    let currentValue: Double
    let baselineValue: Double
    let windowDays: Int

    /// 0 to 1: how much of the window had readings. Patchy history lowers this
    /// instead of hiding the finding.
    let confidence: Double

    let direction: Direction
    let tone: Tone

    // facts only, never advice: AI rewords `meaning`, so advice here comes
    // back out as coaching
    let meaning: String

    // the safety net, shown word for word when AI is unavailable or rejected
    let plainStatement: String
}
