import Foundation

/// Third stage on the path set out in InsightsApp, and the one that answers
/// "where is this heading?". The anomaly stage looks at a single day; this one
/// draws a line through many and reports the ones genuinely drifting.
enum TrendDetector {
    /// The spans a drift is looked for over. Each catches a different pace — a
    /// fast slide shows up in 7 days, a slow one only over 90.
    static let windowDaysOptions = [7, 21, 90]

    /// How much a metric must move across a window, as a fraction of that
    /// window's average, before it counts as a trend. The one sensitivity knob.
    static let relativeChangeThreshold = 0.05

    /// How much of a window needs actual readings before its span is honest.
    /// Three points scattered across 90 days are not a 90-day trend.
    static let minimumCoverage = 0.5

    /// One Finding per metric that is drifting past the threshold. Each metric
    /// is measured up to its own last complete day.
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
            guard let windowEnd = metric.latestCompleteDay(asOf: now, calendar: calendar) else {
                continue
            }
            if let finding = finding(for: metric, in: series, windowEnd: windowEnd, calendar: calendar) {
                findings.append(finding)
            }
        }
        // ranking comes later in the pipeline; alphabetical keeps output stable
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    /// The most sustained drift one metric shows: the longest window with
    /// enough data that moves enough to matter.
    private static func finding(
        for metric: AnalyticMetric,
        in series: [DatedValue],
        windowEnd: Date,
        calendar: Calendar
    ) -> Finding? {
        // longest first: a drift holding over a longer horizon is the more
        // sustained one
        for windowDays in windowDaysOptions.sorted(by: >) {
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

    /// The fitted line over one window, boiled down to what a Finding needs.
    private struct Trend {
        /// How far the line travels across the window, as a signed fraction of
        /// the window's average. This is what meets the threshold.
        let relativeChange: Double
        let mean: Double
        let latestValue: Double
        /// Share of the window's days that had a reading, 0–1.
        let coverage: Double
    }

    /// Best-fit straight line through a window's points, and how far it travels
    /// end to end. x counts days from the window's start, so the slope is a
    /// per-day rate.
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

        // two distinct days are the minimum to define a slope at all
        guard points.count >= 2 else { return nil }

        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count

        var crossDeviation = 0.0   // Σ (x − x̄)(y − ȳ)
        var xVariance = 0.0        // Σ (x − x̄)²
        for point in points {
            crossDeviation += (point.x - meanX) * (point.y - meanY)
            xVariance += (point.x - meanX) * (point.x - meanX)
        }

        // readings all on one day give nothing to slope across, and a zero
        // average gives nothing to be a percentage of
        guard xVariance > 0, meanY != 0 else { return nil }

        let slopePerDay = crossDeviation / xVariance
        let modelledChange = slopePerDay * Double(windowDays - 1)

        // largest day offset is the most recent reading, quoted as "now"
        guard let latestValue = points.max(by: { $0.x < $1.x })?.y else {
            return nil
        }

        return Trend(
            relativeChange: modelledChange / abs(meanY),
            mean: meanY,
            latestValue: latestValue,
            coverage: count / Double(windowDays))
    }

    /// Packs a qualifying drift into a Finding, taking its direction from the
    /// slope's sign.
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
            tone: tone(for: metric, direction: direction),
            meaning: "\(metric.displayName) has \(movement) about \(percent)% over the past "
                + "\(windowDays) days, now around \(metric.formattedWithUnit(trend.latestValue)) "
                + "against a \(windowDays)-day average of \(metric.formattedWithUnit(trend.mean)).",
            plainStatement: "\(metric.displayName) has been trending \(direction == .rising ? "up" : "down") "
                + "over the past \(windowDays) days, about \(percent)% \(higherOrLower).")
    }

    /// Whether a drift is good news, bad news, or just news. Almost the anomaly
    /// stage's table, but activity sliding for weeks earns a caution where a
    /// single quiet day does not.
    private static func tone(for metric: AnalyticMetric, direction: Finding.Direction) -> Finding.Tone {
        switch metric {
        case .quantity(let kind):
            switch kind {
            case .heartRate, .restingHeartRate, .respiratoryRate, .wristTemperature:
                return direction == .rising ? .cautionary : .neutral
            case .hrv, .vo2Max:
                return direction == .falling ? .cautionary : .positive
            case .steps, .activeEnergy:
                return direction == .rising ? .positive : .cautionary
            case .basalEnergy:
                return .neutral
            }
        case .sleepDuration, .deepSleepDuration, .remSleepDuration:
            return direction == .falling ? .cautionary : .neutral
        }
    }
}
