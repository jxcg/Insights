import Foundation

/// The engine's front door, and the last stop before narration on the path set
/// out in InsightsApp. Every detector runs over the same cache and everything
/// they find is ranked together, so only the short list comes back.
enum InsightEngine {
    /// What today is worth saying, best first. Nothing downstream has to know
    /// which stage found what, or how much was discarded.
    static func dailyFindings(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Finding] {
        let everythingFound =
            AnomalyDetector.detect(
                metrics: metrics, nights: nights, asOf: now, calendar: calendar)
            + TrendDetector.detect(
                metrics: metrics, nights: nights, asOf: now, calendar: calendar)
            + CorrelationDetector.detect(
                metrics: metrics, nights: nights, asOf: now, calendar: calendar)

        return FindingRanker.rank(everythingFound)
    }
}
