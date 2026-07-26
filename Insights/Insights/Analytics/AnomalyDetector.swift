import Foundation

/// Second stage on the path set out in InsightsApp, and the one that answers
/// "was yesterday odd?". It compares each metric's latest complete day against
/// the range that metric normally sits in, and turns each surprise into a
/// Finding the narration layer can read out.
enum AnomalyDetector {
    /// How far from the usual mean a value must sit, counted in standard
    /// deviations, before it is worth mentioning. The one sensitivity knob.
    static let zScoreThreshold = 1.5

    /// Days of history the judged value is compared against.
    static let baselineWindowDays = 30

    /// Every metric's latest complete day, judged. A metric with no reading on
    /// that day, or too little history to have a usual range, stays silent.
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
            guard let judgedDay = metric.latestCompleteDay(asOf: now, calendar: calendar) else {
                continue
            }
            if let finding = finding(for: metric, in: series, judgedDay: judgedDay, calendar: calendar) {
                findings.append(finding)
            }
        }
        // ranking comes later in the pipeline; alphabetical keeps output stable
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    /// How unusual one day was, as a z-score against the days before it. The
    /// judged day is deliberately left out of its own baseline — otherwise a
    /// big spike drags the very range it is being measured against.
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
        let period = periodLabel(for: metric)

        return Finding(
            type: .anomaly,
            metric: metric,
            drivingMetric: nil,
            magnitude: abs(zScore),
            currentValue: currentValue,
            baselineValue: baseline.mean,
            windowDays: baselineWindowDays,
            confidence: baseline.coverage,
            direction: direction,
            tone: tone(for: metric, direction: direction),
            meaning: "\(metric.displayName) \(period) sat well \(aboveOrBelow) its usual range: "
                + "\(metric.formattedWithUnit(currentValue)) against a typical "
                + "\(metric.formattedWithUnit(baseline.mean)).",
            plainStatement: "\(metric.displayName) \(period) was "
                + "\(metric.formattedWithUnit(currentValue)), well \(aboveOrBelow) its usual "
                + "\(metric.formattedWithUnit(baseline.mean)).")
    }

    /// When the judged day was, in the words the user would use for it.
    private static func periodLabel(for metric: AnalyticMetric) -> String {
        switch metric {
        case .quantity: "yesterday"
        case .sleepDuration, .deepSleepDuration, .remSleepDuration: "last night"
        }
    }

    /// Whether an odd day is good news, bad news, or just news. Decided here so
    /// the model narrating it can never cheerfully report a warning sign.
    /// Deliberately cautious — one day on its own rarely proves much.
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
}
