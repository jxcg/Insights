import Foundation

/// Third stage of the engine: fits a straight line through each metric's recent
/// history and flags the ones drifting far enough to matter, as sustained-trend
/// Findings. Where the anomaly stage judges a single latest day against its
/// spread, this stage judges the direction of many days together.
enum TrendDetector {
    /// Trailing windows a trend is looked for over, in days. Each is a horizon:
    /// a fast recent drift shows over 7 days, a slow one only over 90.
    static let windowDaysOptions = [7, 21, 90]

    /// Modelled change across a window, as a fraction of the window's mean, that
    /// a metric must reach to count as trending. The single sensitivity knob.
    static let relativeChangeThreshold = 0.05

    /// How populated a window must be for its span to fairly describe the data —
    /// three points scattered across 90 days are not a 90-day trend. Confidence
    /// still scales with the exact coverage above this floor.
    static let minimumCoverage = 0.5

    /// Fits each metric's recent values and emits one Finding per metric that is
    /// drifting past the threshold. Quantity windows end yesterday (today is
    /// still accumulating); sleep windows end today, keyed to the morning woken.
    static func detect(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Finding] {
        let seriesByMetric = BaselineBuilder.dailySeries(
            metrics: metrics, nights: nights, asOf: now)

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return []
        }

        var findings: [Finding] = []
        for (metric, series) in seriesByMetric {
            let windowEnd: Date
            switch metric {
            case .quantity:
                windowEnd = yesterday
            case .sleepDuration, .deepSleepDuration, .remSleepDuration:
                windowEnd = today
            }
            if let finding = finding(for: metric, in: series, windowEnd: windowEnd, calendar: calendar) {
                findings.append(finding)
            }
        }
        // ranking comes later in the pipeline; alphabetical keeps output stable
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    /// The most sustained trend for one metric: the longest window that both
    /// holds enough data and whose fitted line clears the threshold. nil when no
    /// window qualifies — a flat, noisy, or too-sparse series stays silent.
    private static func finding(
        for metric: AnalyticMetric,
        in series: [DatedValue],
        windowEnd: Date,
        calendar: Calendar
    ) -> Finding? {
        // longest first: a drift that holds over a longer horizon is the more
        // sustained one, and reads more meaningfully to the user
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

    /// The straight-line fit over one window, reduced to what a Finding needs.
    private struct Trend {
        /// Modelled change from the window's first day to its last, as a signed
        /// fraction of the window mean — the quantity the threshold is applied to.
        let relativeChange: Double
        let mean: Double
        let latestValue: Double
        /// Share of the window's days that had a reading, 0–1.
        let coverage: Double
    }

    /// Ordinary-least-squares line through the window's points, expressed as the
    /// change it models across the full window relative to the window mean. x is
    /// the day offset from the window start, so the slope is a per-day rate.
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

        // every reading on one day gives no horizontal spread, and a zero mean
        // has no scale to be relative to — neither yields a defensible slope
        guard xVariance > 0, meanY != 0 else { return nil }

        let slopePerDay = crossDeviation / xVariance
        let modelledChange = slopePerDay * Double(windowDays - 1)

        // max(by:) picks the point with the largest day offset — the latest
        // reading — for the Finding's current value; guarded non-nil by count
        guard let latestValue = points.max(by: { $0.x < $1.x })?.y else {
            return nil
        }

        return Trend(
            relativeChange: modelledChange / abs(meanY),
            mean: meanY,
            latestValue: latestValue,
            coverage: count / Double(windowDays))
    }

    /// Turns a qualifying fit into a ready-to-narrate Finding: direction from the
    /// slope's sign, tone from what a lasting drift means for this metric.
    private static func makeFinding(
        metric: AnalyticMetric,
        windowDays: Int,
        trend: Trend
    ) -> Finding {
        let direction: Finding.Direction = trend.relativeChange > 0 ? .rising : .falling
        let percent = Int((abs(trend.relativeChange) * 100).rounded())
        let movement = direction == .rising ? "risen" : "fallen"
        let higherOrLower = direction == .rising ? "higher" : "lower"
        let unit = metric.unitLabel

        return Finding(
            type: .trend,
            metric: metric,
            magnitude: abs(trend.relativeChange),
            currentValue: trend.latestValue,
            baselineValue: trend.mean,
            windowDays: windowDays,
            confidence: trend.coverage,
            direction: direction,
            tone: tone(for: metric, direction: direction),
            meaning: "\(metric.displayName) has \(movement) about \(percent)% over the past "
                + "\(windowDays) days, now around \(formatted(trend.latestValue)) \(unit) "
                + "against a \(windowDays)-day average of \(formatted(trend.mean)) \(unit).",
            plainStatement: "\(metric.displayName) has been trending \(direction == .rising ? "up" : "down") "
                + "over the past \(windowDays) days, about \(percent)% \(higherOrLower).")
    }

    /// How a sustained drift should land, per metric. Mirrors the anomaly stage,
    /// except a lasting fall in activity earns a caution where a single low day
    /// would not — a trend carries more weight than one odd day.
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

    /// Copy shows whole numbers plainly and everything else to one decimal.
    private static func formatted(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
