import Foundation

/// One day, one number. The plainest shape the maths can work on — tests build
/// these by hand, the app derives them from the cache.
struct DatedValue {
    let day: Date
    let value: Double
}

/// What "usual" means for one metric over a stretch of days: the average it
/// sits around and how much it normally wanders either side. Everything the
/// engine calls unusual is unusual relative to this.
struct MetricBaseline {
    let windowDays: Int
    let mean: Double
    /// How much the metric normally wanders. nil below two days — a single
    /// reading cannot tell you anything about spread.
    let standardDeviation: Double?
    let sampleCount: Int
    /// Share of the window that had readings, 0–1. Findings scale their
    /// confidence with this rather than refusing when history is thin.
    let coverage: Double

    /// The usual range over the days ending on endDay. Works from one day's
    /// data upwards; nil only when the window is completely empty.
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
        // behaves, not the whole story
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
