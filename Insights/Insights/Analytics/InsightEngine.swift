import Foundation

/// The engine's front door, and the last stop before narration on the path set
/// out in InsightsApp. Every detector runs over the same cache, everything they
/// find is ranked together, and only the short list comes back — which is all
/// the narration layer, and therefore the model, will ever see.
enum InsightEngine {
    /// What today is worth saying, best first. Callers hand over the cache as
    /// it stands and get a list already cut to size; nothing downstream has to
    /// know which stage found what, or how many findings were discarded.
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
