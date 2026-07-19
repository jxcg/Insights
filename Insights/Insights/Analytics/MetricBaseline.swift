import Foundation

/// One day's value for one metric, as plain data the maths can run on —
/// tests hand-build these, the app derives them from the cached records.
struct DatedValue {
    let day: Date
    let value: Double
}

/// A metric's usual range over a trailing window: the rolling mean and spread
/// that anomaly and trend detection compare a current value against.
struct MetricBaseline {
    let windowDays: Int
    let mean: Double
    /// Sample standard deviation; nil below two days — one reading has no spread.
    let standardDeviation: Double?
    let sampleCount: Int
    /// Share of the window that actually had data, 0–1. Findings scale their
    /// confidence with this instead of the maths refusing when history is thin.
    let coverage: Double

    /// Baseline over the trailing window ending on endDay inclusive.
    /// Works from a single day's data upwards; nil only when the window holds
    /// no data at all.
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

        // sample (n-1) deviation: the window is a sample of the metric's behaviour
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
