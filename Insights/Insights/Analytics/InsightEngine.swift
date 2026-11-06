import Foundation

/// Runs all three detectors, returns the day's best findings.
/// Rest of the app only calls this.
enum InsightEngine {
    // callers don't need to know which detector found what, or how much got
    // thrown away
    static func dailyFindings(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Finding] {
        dailyFindings(
            history: HealthHistory(metrics: metrics, nights: nights), asOf: now, calendar: calendar)
    }

    // the series are built once and shared by all three detectors
    static func dailyFindings(
        history: HealthHistory,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Finding] {
        let series = history.series(asOf: now)
        return FindingRanker.rank(
            AnomalyDetector.detect(series, asOf: now, calendar: calendar)
                + TrendDetector.detect(series, asOf: now, calendar: calendar)
                + CorrelationDetector.detect(series, asOf: now, calendar: calendar))
    }
}
