import Foundation

/// Answers "where is this heading?".
///
/// The anomaly detector looks at a single day. This one draws a line through
/// many days and reports the metrics genuinely drifting up or down.
enum TrendDetector {
    /// Window lengths to look for a drift over, longest first. Each catches a
    /// different pace: a fast slide shows up in 7 days, a slow one only over 90.
    /// A drift holding over more days is the more sustained one, so the first
    /// window that qualifies wins.
    static let windowDaysOptions = [90, 21, 7]

    /// How far a metric must move across a window, as a fraction of that
    /// window's average, to count as a trend. 0.05 is 5%. The one sensitivity
    /// knob.
    static let relativeChangeThreshold = 0.05

    /// How much of a window needs real readings before its length is honest.
    /// Three readings scattered across 90 days are not a 90-day trend.
    static let minimumCoverage = 0.5

    /// One Finding per metric drifting past the threshold. Each metric is
    /// measured up to its own last complete day.
    static func detect(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Finding] {
        let seriesByMetric = BaselineBuilder.dailySeries(
            metrics: metrics, nights: nights, asOf: now)

        var findings: [Finding] = []
        for (metric, series) in seriesByMetric {
            let windowEnd = metric.latestCompleteDay(asOf: now, calendar: calendar)
            if let finding = finding(for: metric, in: series, windowEnd: windowEnd, calendar: calendar) {
                findings.append(finding)
            }
        }
        // FindingRanker sorts properly later. Alphabetical just keeps the
        // output the same from run to run.
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    /// The most sustained drift one metric shows: the longest window that has
    /// enough data and moves enough to matter.
    private static func finding(
        for metric: AnalyticMetric,
        in series: [DatedValue],
        windowEnd: Date,
        calendar: Calendar
    ) -> Finding? {
        for windowDays in windowDaysOptions {
            guard let trend = fitTrend(
                over: series, windowDays: windowDays,
                endingOn: windowEnd, calendar: calendar) else {
                continue
            }
            guard trend.coverage >= minimumCoverage,
                  abs(trend.relativeChange) >= relativeChangeThreshold else {
                continue
            }
            return makeFinding(metric: metric, windowDays: windowDays, trend: trend)
        }
        return nil
    }

    /// The fitted line, reduced to what a Finding needs.
    private struct Trend {
        /// How far the line travels across the window, as a signed fraction of
        /// the window's average. This is the number that meets the threshold.
        let relativeChange: Double
        let mean: Double
        let latestValue: Double
        /// Share of the window's days that had a reading, 0 to 1.
        let coverage: Double
    }

    /// Fits a straight line through one window's readings and reports how far
    /// that line travels start to end.
    ///
    /// This is least-squares regression: the line sitting closest to all the
    /// points at once. x counts days from the window's start, so the slope
    /// comes out as change per day.
    private static func fitTrend(
        over series: [DatedValue],
        windowDays: Int,
        endingOn windowEnd: Date,
        calendar: Calendar
    ) -> Trend? {
        let end = calendar.startOfDay(for: windowEnd)
        guard let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: end) else {
            return nil
        }

        let points: [(x: Double, y: Double)] = series.compactMap { dated in
            let day = calendar.startOfDay(for: dated.day)
            guard day >= start, day <= end,
                  let offset = calendar.dateComponents([.day], from: start, to: day).day else {
                return nil
            }
            return (x: Double(offset), y: dated.value)
        }

        // two distinct days is the minimum to draw a slope through at all
        guard points.count >= 2 else { return nil }

        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count

        // the two halves of the slope formula: how x and y vary together, over
        // how much x varies on its own
        var crossDeviation = 0.0   // sum of (x - meanX)(y - meanY)
        var xVariance = 0.0        // sum of (x - meanX) squared
        for point in points {
            crossDeviation += (point.x - meanX) * (point.y - meanY)
            xVariance += (point.x - meanX) * (point.x - meanX)
        }

        // all readings on one day gives nothing to slope across, and a zero
        // average gives nothing to be a percentage of
        guard xVariance > 0, meanY != 0 else { return nil }

        let slopePerDay = crossDeviation / xVariance
        let modelledChange = slopePerDay * Double(windowDays - 1)

        // biggest day offset is the most recent reading, quoted as "now"
        guard let latestValue = points.max(by: { $0.x < $1.x })?.y else {
            return nil
        }

        return Trend(
            relativeChange: modelledChange / abs(meanY),
            mean: meanY,
            latestValue: latestValue,
            coverage: count / Double(windowDays))
    }

    /// Turns a qualifying drift into a Finding. Direction comes from the sign
    /// of the slope.
    private static func makeFinding(
        metric: AnalyticMetric,
        windowDays: Int,
        trend: Trend
    ) -> Finding {
        let direction: Finding.Direction = trend.relativeChange > 0 ? .rising : .falling
        let percent = Int((abs(trend.relativeChange) * 100).rounded())
        let movement = direction == .rising ? "risen" : "fallen"
        let higherOrLower = direction == .rising ? "higher" : "lower"

        return Finding(
            type: .trend,
            metric: metric,
            drivingMetric: nil,
            magnitude: abs(trend.relativeChange),
            currentValue: trend.latestValue,
            baselineValue: trend.mean,
            windowDays: windowDays,
            confidence: trend.coverage,
            direction: direction,
            // weeks of drift, so falling activity earns a caution here
            tone: metric.tone(direction: direction, sustained: true),
            meaning: "\(metric.displayName) has \(movement) about \(percent)% over the past "
                + "\(windowDays) days, now around \(metric.formattedWithUnit(trend.latestValue)) "
                + "against a \(windowDays)-day average of \(metric.formattedWithUnit(trend.mean)).",
            plainStatement: "\(metric.displayName) has been trending \(direction == .rising ? "up" : "down") "
                + "over the past \(windowDays) days, about \(percent)% \(higherOrLower).")
    }
}
