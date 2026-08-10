import Foundation

/// One reading: a day and a number. The simplest shape the maths works on.
struct DatedValue {
    let day: Date
    let value: Double
}

/// What "normal" looks like for one metric over a stretch of days: the average,
/// and how much it usually varies around that average. Everything the engine
/// calls unusual is unusual compared to this.
struct MetricBaseline {
    let windowDays: Int
    let mean: Double
    /// How much the metric normally varies. nil below 2 readings, because a
    /// single number has nothing to vary against.
    let standardDeviation: Double?
    let sampleCount: Int
    /// How full the window was, 0 to 1. 15 readings over 30 days is 0.5.
    /// Findings scale their confidence with this instead of giving up when
    /// history is thin.
    let coverage: Double

    /// The normal range over the `windowDays` ending on `endDay`. One day of
    /// data is enough. nil only when the window is empty.
    static func compute(
        over series: [DatedValue],
        windowDays: Int,
        endingOn endDay: Date,
        calendar: Calendar = .current
    ) -> MetricBaseline? {
        let windowEnd = calendar.startOfDay(for: endDay)
        guard let windowStart = calendar.date(
            byAdding: .day, value: -(windowDays - 1), to: windowEnd) else {
            return nil
        }

        let valuesInWindow = series
            .filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= windowStart && day <= windowEnd
            }
            .map(\.value)

        guard !valuesInWindow.isEmpty else {
            return nil
        }

        let mean = valuesInWindow.reduce(0, +) / Double(valuesInWindow.count)

        // divide by n-1, not n: these days are a sample of how the metric
        // behaves, not every day it ever had
        var standardDeviation: Double?
        if valuesInWindow.count >= 2 {
            let squaredDeviations = valuesInWindow.map { ($0 - mean) * ($0 - mean) }
            let variance = squaredDeviations.reduce(0, +) / Double(valuesInWindow.count - 1)
            standardDeviation = variance.squareRoot()
        }

        return MetricBaseline(
            windowDays: windowDays,
            mean: mean,
            standardDeviation: standardDeviation,
            sampleCount: valuesInWindow.count,
            coverage: Double(valuesInWindow.count) / Double(windowDays))
    }
}
