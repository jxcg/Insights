import Foundation

/// First step whenever the engine runs: turns the cached records into rolling
/// 30- and 60-day baselines for every metric that has data.
enum BaselineBuilder {
    /// The two horizons every current value gets judged against. Either can be
    /// nil when its window holds no data — a metric with no data at all is
    /// absent from the result entirely.
    struct RollingBaselines {
        let thirtyDay: MetricBaseline?
        let sixtyDay: MetricBaseline?
    }

    /// Quantity windows end yesterday: today is still accumulating and would
    /// drag sums down. Sleep windows end today: a night is complete once woken,
    /// and it is keyed to the morning it ended.
    static func build(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [AnalyticMetric: RollingBaselines] {
        var seriesByMetric: [AnalyticMetric: [DatedValue]] = [:]

        for record in metrics {
            guard let kind = MetricKind(rawValue: record.metricKind) else {
                continue
            }
            seriesByMetric[.quantity(kind), default: []]
                .append(DatedValue(day: record.date, value: record.value))
        }

        // durations cached in seconds, analysed in hours
        // a night only counts once the user has been awake past the session
        // gap — sooner, and more sleep could still be glued onto it
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

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return [:]
        }

        var baselines: [AnalyticMetric: RollingBaselines] = [:]
        for (metric, series) in seriesByMetric {
            let windowEnd: Date
            switch metric {
            case .quantity:
                windowEnd = yesterday
            case .sleepDuration, .deepSleepDuration, .remSleepDuration:
                windowEnd = today
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
