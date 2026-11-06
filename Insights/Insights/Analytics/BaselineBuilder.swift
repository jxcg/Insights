import Foundation

/// The cache copied out of SwiftData once, as plain values, so one refresh
/// reads each stored record once rather than once per detector and per
/// morning.
///
/// Sync writes records in whatever shape suited it. Maths wants one sorted
/// list of (day, value) per metric; `series(asOf:)` gives that.
struct HealthHistory {
    /// One night, as plain values.
    struct Night {
        let wakeDay: Date
        let end: Date
        let asleep: TimeInterval
        let deep: TimeInterval?
        let rem: TimeInterval?
    }

    // records arrive unordered, and adding the same numbers in a different
    // order gives slightly different totals. That is floating point. Sorting
    // once here is what makes two runs agree.
    private let quantities: [AnalyticMetric: [DatedValue]]
    let nights: [Night]

    /// true only when the cache holds no records at all, of any kind
    let isEmpty: Bool

    init(metrics: [DailyMetricRecord], nights: [SleepNightRecord]) {
        isEmpty = metrics.isEmpty && nights.isEmpty
        var quantities: [AnalyticMetric: [DatedValue]] = [:]
        for record in metrics {
            guard let kind = MetricKind(rawValue: record.metricKind) else { continue }
            quantities[.quantity(kind), default: []]
                .append(DatedValue(day: record.date, value: record.value))
        }
        self.quantities = quantities.mapValues { $0.sorted { $0.day < $1.day } }
        self.nights = nights
            .map { Night(wakeDay: $0.wakeDay, end: $0.end, asleep: $0.asleep, deep: $0.deep, rem: $0.rem) }
            .sorted { $0.wakeDay < $1.wakeDay }
    }

    /// One day-by-day series per metric, as things stood at `now`. Every
    /// detector starts here, so they all judge the same numbers.
    ///
    /// Sleep is stored in seconds, analysed in hours. A night joins only once
    /// the user has been awake past the session gap: before that, more sleep
    /// could still be added to it.
    func series(asOf now: Date) -> [AnalyticMetric: [DatedValue]] {
        var seriesByMetric = quantities
        var asleep: [DatedValue] = []
        var deep: [DatedValue] = []
        var rem: [DatedValue] = []
        for night in nights where now.timeIntervalSince(night.end) >= SleepNightAggregator.sessionGap {
            asleep.append(DatedValue(day: night.wakeDay, value: night.asleep / 3600))
            if let seconds = night.deep { deep.append(DatedValue(day: night.wakeDay, value: seconds / 3600)) }
            if let seconds = night.rem { rem.append(DatedValue(day: night.wakeDay, value: seconds / 3600)) }
        }
        if !asleep.isEmpty { seriesByMetric[.sleepDuration] = asleep }
        if !deep.isEmpty { seriesByMetric[.deepSleepDuration] = deep }
        if !rem.isEmpty { seriesByMetric[.remSleepDuration] = rem }
        return seriesByMetric
    }

    /// The night that ended on `day`'s morning, if there was one.
    func night(wakingOn day: Date, calendar: Calendar) -> Night? {
        nights.first { calendar.startOfDay(for: $0.wakeDay) == day }
    }
}

enum BaselineBuilder {
    /// Records straight to series, for callers that only need them once.
    static func dailySeries(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now
    ) -> [AnalyticMetric: [DatedValue]] {
        HealthHistory(metrics: metrics, nights: nights).series(asOf: now)
    }
}
