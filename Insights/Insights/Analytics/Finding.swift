import Foundation

/// One interpreted result from the analytics engine, ready to show or narrate.
/// The engine decides direction, tone, and meaning before any AI sees it — the
/// language model only ever rephrases a Finding, never interprets the numbers.
struct Finding {
    /// What kind of pattern the engine spotted.
    enum FindingType: String {
        /// Today sits well outside the metric's usual range.
        case anomaly
        /// The metric has been drifting across recent days.
        case trend
        /// Two metrics move together across days.
        case correlation
    }

    /// Which way the metric moved relative to its baseline. Just the movement —
    /// whether that movement is good or bad depends on the metric and lives in tone.
    enum Direction: String {
        case rising
        case falling
        case steady
    }

    /// How the change should land with the user, decided by the engine so
    /// narration can never present a bad sign as a good one.
    enum Tone: String {
        case positive
        case neutral
        case cautionary
    }

    let type: FindingType
    let metric: AnalyticMetric

    /// Effect size in the finding's own terms: baseline SDs for an anomaly,
    /// change over the window for a trend, strength for a correlation.
    let magnitude: Double

    let currentValue: Double
    /// The rolling mean the current value was judged against.
    let baselineValue: Double
    /// Days of history the comparison used.
    let windowDays: Int
    /// 0–1, growing with how much of the window actually had data — thin
    /// history lowers this rather than suppressing the finding.
    let confidence: Double

    let direction: Direction
    let tone: Tone
    /// What the numbers mean for this user. Descriptive, never instructive —
    /// narration rephrases it, so it must carry facts, not advice.
    let meaning: String
    /// Deterministic full sentence shown verbatim whenever AI narration is
    /// unavailable or rejected.
    let plainStatement: String
}
