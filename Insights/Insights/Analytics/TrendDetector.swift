import Foundation

/// "Where is this heading?"
///
/// Anomaly detector looks at one day. This draws a line through many days and
/// reports metrics genuinely drifting.
enum TrendDetector {
    // longest first: a fast slide shows in 7 days, a slow one only over 90.
    // Longer drift is more sustained, so the first window to qualify wins.
    static let windowDaysOptions = [90, 21, 7]

    // how far a metric must move across a window, as a fraction of that
    // window's average. Main sensitivity knob.
    static let relativeChangeThreshold = 0.05

    // three readings across 90 days is not a 90-day trend
    static let minimumCoverage = 0.5

    /// One Finding per metric drifting past the threshold, each measured up to
    /// its own last complete day.
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
        // FindingRanker sorts properly later. Alphabetical just keeps output
        // the same run to run.
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    // most sustained drift a metric shows: longest window with enough data
    // that moves enough to matter
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

    private struct Trend {
        // how far the line travels, as a signed fraction of the window's
        // average. This is what meets the threshold.
        let relativeChange: Double
        let mean: Double
        let latestValue: Double
        let coverage: Double
    }

    /// Fits a straight line through a window's readings, reports how far it
    /// travels start to end.
    ///
    /// Least-squares regression: the line sitting closest to all points at
    /// once. x counts days from window start, so slope is change per day.
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

        // the two halves of the slope formula: how x and y vary together,
        // divided by how much x varies on its own
        var crossDeviation = 0.0   // sum of (x - meanX)(y - meanY)
        var xVariance = 0.0        // sum of (x - meanX) squared
        for point in points {
            crossDeviation += (point.x - meanX) * (point.y - meanY)
            xVariance += (point.x - meanX) * (point.x - meanX)
        }

        // all readings on one day: nothing to slope across.
        // zero average: nothing to be a percentage of.
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
