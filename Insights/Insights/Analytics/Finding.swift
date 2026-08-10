import Foundation

/// One thing worth telling the user. All judging already done.
///
/// Swift decides what moved, which way, whether it matters. AI only rewords
/// it. AI never decides what numbers mean.
struct Finding {
    /// Which detector found this.
    enum FindingType: String {
        /// One day well outside normal range.
        case anomaly
        /// Drifting the same way for a while.
        case trend
        /// Two metrics move together.
        case correlation
    }

    /// Which way it moved. Movement only. Good or bad is `tone`.
    enum Direction: String {
        case rising
        case falling
        case steady
    }

    /// Good news, bad news, or just news. Set here so AI can't narrate a
    /// warning sign cheerfully.
    enum Tone: String {
        case positive
        case neutral
        case cautionary
    }

    let type: FindingType
    /// What this finding is about. For a correlation, the outcome: the metric
    /// the user cares about, not the one driving it.
    let metric: AnalyticMetric
    /// For a correlation, the metric that seems to move `metric`.
    /// nil for single-metric findings.
    let drivingMetric: AnalyticMetric?

    /// How big the effect is, in each detector's own units: standard
    /// deviations for an anomaly, percent for a trend, r for a correlation.
    /// `FindingRanker` converts these onto one scale.
    let magnitude: Double

    let currentValue: Double
    /// Normal value `currentValue` was compared against.
    let baselineValue: Double
    /// Days of history behind the comparison.
    let windowDays: Int
    /// 0 to 1: how much of the window had readings. Patchy history lowers this
    /// instead of hiding the finding.
    let confidence: Double

    let direction: Direction
    let tone: Tone
    /// What the numbers mean for this user. Facts only, never advice.
    /// AI rewords this, so advice here comes out as coaching.
    let meaning: String
    /// Ready-made sentence. Shown word for word when AI is unavailable or its
    /// answer gets rejected.
    let plainStatement: String
}
