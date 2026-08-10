import Foundation

/// Turns cached records into the tidy series every detector reads.
///
/// The sync writes records in whatever shape suited it. The maths wants one
/// sorted list of (day, value) per metric.
enum BaselineBuilder {
    /// The cache flattened into one day-by-day series per metric. Every
    /// detector starts here, so they all judge the same numbers.
    static func dailySeries(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now
    ) -> [AnalyticMetric: [DatedValue]] {
        var seriesByMetric: [AnalyticMetric: [DatedValue]] = [:]

        for record in metrics {
            guard let kind = MetricKind(rawValue: record.metricKind) else {
                continue
            }
            seriesByMetric[.quantity(kind), default: []]
                .append(DatedValue(day: record.date, value: record.value))
        }

        // sleep is stored in seconds but analysed in hours. A night is skipped
        // until the user has been awake past the session gap, because until
        // then more sleep could still get added to it
        for record in nights {
            guard now.timeIntervalSince(record.end) >= SleepNightAggregator.sessionGap else {
                continue
            }
            seriesByMetric[.sleepDuration, default: []]
                .append(DatedValue(day: record.wakeDay, value: record.asleep / 3600))
            if let deep = record.deep {
                seriesByMetric[.deepSleepDuration, default: []]
                    .append(DatedValue(day: record.wakeDay, value: deep / 3600))
            }
            if let rem = record.rem {
                seriesByMetric[.remSleepDuration, default: []]
                    .append(DatedValue(day: record.wakeDay, value: rem / 3600))
            }
        }
        // records arrive in no particular order, and adding the same numbers in
        // a different order gives very slightly different totals. That is how
        // floating point works. Sorting here is what makes two runs over the
        // same data agree.
        return seriesByMetric.mapValues { series in
            series.sorted { $0.day < $1.day }
        }
    }
}
