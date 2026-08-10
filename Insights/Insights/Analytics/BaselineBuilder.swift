import Foundation

/// Turns cached records into the tidy series detectors read.
///
/// Sync writes records in whatever shape suited it. Maths wants one sorted
/// list of (day, value) per metric.
enum BaselineBuilder {
    /// Cache flattened into one day-by-day series per metric.
    /// Every detector starts here, so they all judge the same numbers.
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

        // sleep is stored in seconds, analysed in hours. Skip a night until the
        // user has been awake past the session gap: before that, more sleep
        // could still be added to it
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
        // records arrive unordered, and adding the same numbers in a different
        // order gives slightly different totals. That is floating point.
        // Sorting here is what makes two runs agree.
        return seriesByMetric.mapValues { series in
            series.sorted { $0.day < $1.day }
        }
    }
}
