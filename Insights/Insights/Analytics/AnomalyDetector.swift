import Foundation

/// "Was yesterday odd?"
///
/// Compares each metric's last complete day to its normal range.
/// Far enough outside becomes a Finding.
enum AnomalyDetector {
    /// How far from normal before we mention it, in standard deviations
    /// ("z-score"). 1.5 flags about 1 day in 7. Main sensitivity knob.
    static let zScoreThreshold = 1.5

    /// Days of history the judged value is compared against.
    static let baselineWindowDays = 30

    /// Judges every metric's last complete day. Stays silent when a metric has
    /// no reading that day, or too little history to have a normal range.
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
            let judgedDay = metric.latestCompleteDay(asOf: now, calendar: calendar)
            if let finding = finding(for: metric, in: series, judgedDay: judgedDay, calendar: calendar) {
                findings.append(finding)
            }
        }
        // FindingRanker sorts properly later. Alphabetical just keeps output
        // the same run to run.
        return findings.sorted { $0.metric.displayName < $1.metric.displayName }
    }

    /// How unusual one day was, as a z-score: how many standard deviations it
    /// sits from the recent average.
    ///
    /// Judged day is left out of its own baseline on purpose. Otherwise a big
    /// spike drags up the average it is measured against, and looks less
    /// unusual than it is.
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
            // one odd day proves little, so activity gets the lenient reading
            tone: metric.tone(direction: direction, sustained: false),
            meaning: "\(metric.displayName) \(period) sat well \(aboveOrBelow) its usual range: "
                + "\(metric.formattedWithUnit(currentValue)) against a typical "
                + "\(metric.formattedWithUnit(baseline.mean)).",
            plainStatement: "\(metric.displayName) \(period) was "
                + "\(metric.formattedWithUnit(currentValue)), well \(aboveOrBelow) its usual "
                + "\(metric.formattedWithUnit(baseline.mean)).")
    }

    /// What to call the judged day: "yesterday" or "last night".
    private static func periodLabel(for metric: AnalyticMetric) -> String {
        switch metric {
        case .quantity: "yesterday"
        case .sleepDuration, .deepSleepDuration, .remSleepDuration: "last night"
        }
    }
}
