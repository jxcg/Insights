import Foundation

/// The hand-off the whole app is built around: one thing worth telling the
/// user, with every judgement already made. Which way it moved, whether that
/// is a worry, and what it means are all settled here in Swift, so the model
/// that reads it aloud has nothing left to get wrong.
struct Finding {
    /// Which stage of the engine spotted this.
    enum FindingType: String {
        /// One day sat well outside the metric's usual range.
        case anomaly
        /// The metric has been drifting for a while.
        case trend
        /// Two metrics tend to move together.
        case correlation
    }

    /// Which way the metric went. Movement only — whether that is good or bad
    /// depends on the metric, and lives in tone.
    enum Direction: String {
        case rising
        case falling
        case steady
    }

    /// How this should land with the user. Set here so narration can never
    /// dress a warning sign up as good news.
    enum Tone: String {
        case positive
        case neutral
        case cautionary
    }

    let type: FindingType
    /// What the finding is about. For a correlation this is the outcome — the
    /// metric the user actually cares about.
    let metric: AnalyticMetric
    /// For a correlation, the metric that appears to move the outcome. nil when
    /// the finding is about a single series.
    let drivingMetric: AnalyticMetric?

    /// How big the effect is, in whichever terms the stage works in: standard
    /// deviations for an anomaly, percentage change for a trend, r for a
    /// correlation. Used to rank findings against each other.
    let magnitude: Double

    let currentValue: Double
    /// The usual value the current one was judged against.
    let baselineValue: Double
    /// Days of history behind the comparison.
    let windowDays: Int
    /// 0–1, rising with how much of the window actually had readings. Thin
    /// history lowers this rather than hiding the finding.
    let confidence: Double

    let direction: Direction
    let tone: Tone
    /// What the numbers mean for this user. Facts, never advice — the model
    /// rephrases this, so anything instructive here would come out as coaching.
    let meaning: String
    /// A complete sentence, written by us, shown word for word whenever the
    /// model is unavailable or its answer is rejected.
    let plainStatement: String
}
