import Foundation

/// Where every engine run begins. The cache holds records in the shape the
/// sync wrote them; the detectors want one tidy series per metric. This turns
/// the first into the second, and works out what "usual" looks like.
enum BaselineBuilder {
    /// A metric's usual range read over two horizons at once, so a value can be
    /// weighed against both the recent past and a longer one. Either is nil
    /// when its window holds no data.
    struct RollingBaselines {
        let thirtyDay: MetricBaseline?
        let sixtyDay: MetricBaseline?
    }

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

        // sleep is cached in seconds but analysed in hours, and a night only
        // counts once the user has stayed awake past the session gap — sooner,
        // and more sleep could still be glued onto it
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
        // the cache hands records over in no promised order, and summing the
        // same days in a different order lands on very slightly different
        // totals. Sorting here is what makes every stage downstream give the
        // same answer twice.
        return seriesByMetric.mapValues { series in
            series.sorted { $0.day < $1.day }
        }
    }

    /// Both baselines for every metric that has any data at all. Each window
    /// ends on the metric's last complete day, so a half-finished today can
    /// never drag the usual range down with it.
    static func build(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [AnalyticMetric: RollingBaselines] {
        let seriesByMetric = dailySeries(metrics: metrics, nights: nights, asOf: now)

        var baselines: [AnalyticMetric: RollingBaselines] = [:]
        for (metric, series) in seriesByMetric {
            guard let windowEnd = metric.latestCompleteDay(asOf: now, calendar: calendar) else {
                continue
            }

            let thirtyDay = MetricBaseline.compute(
                over: series, windowDays: 30, endingOn: windowEnd, calendar: calendar)
            let sixtyDay = MetricBaseline.compute(
                over: series, windowDays: 60, endingOn: windowEnd, calendar: calendar)

            if thirtyDay != nil || sixtyDay != nil {
                baselines[metric] = RollingBaselines(thirtyDay: thirtyDay, sixtyDay: sixtyDay)
            }
        }
        return baselines
    }
}
