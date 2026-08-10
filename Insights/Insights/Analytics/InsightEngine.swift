import Foundation

/// Runs all three detectors, returns the day's best findings.
/// Rest of the app only calls this.
enum InsightEngine {
    /// Today's findings, best first. Callers don't need to know which detector
    /// found what, or how much got thrown away.
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
