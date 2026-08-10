import Foundation

/// One thing worth telling the user, with the judging already done.
///
/// Swift decides what moved, which way, and whether it matters. The AI only
/// rewords this into friendlier English. It never decides what numbers mean.
struct Finding {
    /// Which detector found this.
    enum FindingType: String {
        /// One day well outside the metric's normal range.
        case anomaly
        /// The metric has been drifting the same way for a while.
        case trend
        /// Two metrics tend to move together.
        case correlation
    }

    /// Which way the metric moved. Movement only. Good or bad is `tone`.
    enum Direction: String {
        case rising
        case falling
        case steady
    }

    /// Good news, bad news, or just news. Set here so the AI cannot cheerfully
    /// narrate a warning sign.
    enum Tone: String {
        case positive
        case neutral
        case cautionary
    }

    let type: FindingType
    /// What this finding is about. For a correlation it is the outcome: the
    /// metric the user cares about, not the one driving it.
    let metric: AnalyticMetric
    /// For a correlation, the metric that seems to move `metric`.
    /// nil for findings about a single metric.
    let drivingMetric: AnalyticMetric?

    /// How big the effect is, in each detector's own units: standard deviations
    /// for an anomaly, percent change for a trend, r for a correlation.
    /// `FindingRanker` converts these onto one scale.
    let magnitude: Double

    let currentValue: Double
    /// The normal value `currentValue` was compared against.
    let baselineValue: Double
    /// How many days of history the comparison used.
    let windowDays: Int
    /// 0 to 1, how much of the window actually had readings. Patchy history
    /// lowers this instead of hiding the finding.
    let confidence: Double

    let direction: Direction
    let tone: Tone
    /// What the numbers mean for this user. Facts only, never advice. The AI
    /// rewords this, so advice here would come out as coaching.
    let meaning: String
    /// A ready-made sentence, shown word for word when the AI is unavailable
    /// or its answer gets rejected.
    let plainStatement: String
}
