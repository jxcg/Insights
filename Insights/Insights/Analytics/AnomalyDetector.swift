import Foundation

/// Second stage of the engine: flags metrics whose latest complete value sits
/// well outside their recent usual range, measured in baseline standard
/// deviations, and emits each hit as a ready-made Finding.
enum AnomalyDetector {
    /// How many baseline SDs from the mean a value must sit to count as an
    /// anomaly. The single sensitivity knob.
    static let zScoreThreshold = 1.5

    /// Days of trailing history the judged value is compared against.
    static let baselineWindowDays = 30

    /// Judges each metric's latest complete value: yesterday for quantities
    /// (today is still accumulating), this morning for sleep. Metrics with no
    /// value on that day, or too little history for a spread, stay silent.
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
            let judgedDay: Date
            switch metric {
            case .quantity:
                judgedDay = yesterday
            case .sleepDuration, .deepSleepDuration, .remSleepDuration:
                judgedDay = today
            }
            if let finding = finding(for: metric, in: series, judgedDay: judgedDay, calendar: calendar) {
                findings.append(finding)
            }
        }
        // ranking comes later in the pipeline; alphabetical keeps output stable
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    /// Z-score of the judged day's value against the window of days before it.
    /// The judged value is kept out of its own baseline so a spike cannot drag
    /// the range it is measured against towards itself.
    private static func finding(
        for metric: AnalyticMetric,
        in series: [DatedValue],
        judgedDay: Date,
        calendar: Calendar
    ) -> Finding? {
        guard let currentValue = series
            .first(where: { calendar.startOfDay(for: $0.day) == judgedDay })?.value else {
            return nil
        }

        guard let baselineEnd = calendar.date(byAdding: .day, value: -1, to: judgedDay),
              let baseline = MetricBaseline.compute(
                over: series, windowDays: baselineWindowDays,
                endingOn: baselineEnd, calendar: calendar),
              let spread = baseline.standardDeviation, spread > 0 else {
            return nil
        }

        let zScore = (currentValue - baseline.mean) / spread
        guard abs(zScore) >= zScoreThreshold else {
            return nil
        }

        let direction: Finding.Direction = zScore > 0 ? .rising : .falling
        let aboveOrBelow = direction == .rising ? "above" : "below"
        let unit = metric.unitLabel
        let period = periodLabel(for: metric)

        return Finding(
            type: .anomaly,
            metric: metric,
            magnitude: abs(zScore),
            currentValue: currentValue,
            baselineValue: baseline.mean,
            windowDays: baselineWindowDays,
            confidence: baseline.coverage,
            direction: direction,
            tone: tone(for: metric, direction: direction),
            meaning: "\(metric.displayName) \(period) sat well \(aboveOrBelow) its usual range: "
                + "\(formatted(currentValue)) \(unit) against a typical \(formatted(baseline.mean)) \(unit).",
            plainStatement: "\(metric.displayName) \(period) was \(formatted(currentValue)) \(unit), "
                + "well \(aboveOrBelow) its usual \(formatted(baseline.mean)) \(unit).")
    }

    /// When the judged value happened, in the user's terms — quantities are
    /// judged on yesterday's complete day, sleep on the night just ended.
    private static func periodLabel(for metric: AnalyticMetric) -> String {
        switch metric {
        case .quantity: "yesterday"
        case .sleepDuration, .deepSleepDuration, .remSleepDuration: "last night"
        }
    }

    /// How a one-day departure from usual should land, per metric. Deliberately
    /// conservative: positive only where the direction is a genuinely good
    /// sign, neutral wherever a single day proves little.
    private static func tone(for metric: AnalyticMetric, direction: Finding.Direction) -> Finding.Tone {
        switch metric {
        case .quantity(let kind):
            switch kind {
            case .heartRate, .restingHeartRate, .respiratoryRate, .wristTemperature:
                direction == .rising ? .cautionary : .neutral
            case .hrv, .vo2Max:
                direction == .falling ? .cautionary : .positive
            case .steps, .activeEnergy:
                direction == .rising ? .positive : .neutral
            case .basalEnergy:
                .neutral
            }
        case .sleepDuration, .deepSleepDuration, .remSleepDuration:
            direction == .falling ? .cautionary : .neutral
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
