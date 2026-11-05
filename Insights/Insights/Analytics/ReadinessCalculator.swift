import Foundation

/// "How recovered am I this morning?", as one number from 0 to 100.
///
/// Built only from the user's own history, never population norms. Each
/// input is scored by how far its latest reading sits from that person's
/// recent normal, in standard deviations (a z-score), flipped where lower is
/// better. The inputs are combined into one composite z-score:
///
///     composite = Σ weight × z  ÷  √(Σ weight²)
///     score     = 70 + 15 × composite, held between 0 and 100
///
/// Dividing by √(Σ weight²) rather than Σ weight keeps the composite on the
/// same scale as a single z-score: if the inputs vary independently, it has a
/// standard deviation of 1, whether one input is present or all three. A plain
/// weighted average would shrink towards 0, and mornings with fewer inputs
/// would swing further.
///
/// So an ordinary morning scores 70, and each standard deviation of the
/// composite moves it 15 points. The low-recovery line at 55 is one standard
/// deviation below the user's own normal: roughly one morning in six if the
/// inputs vary independently, more often if they move together. That rate is
/// the thing to check against real history (#29). The 70 and the 15 only set
/// how the number reads; together they fix where the line falls.
///
/// Timing: HRV and resting heart rate are judged on yesterday, the last
/// complete day. Sleep is last night, but only once it has settled (two hours
/// after waking); until then the score is built without it, and the Summary
/// says so.
enum ReadinessCalculator {
    static let typicalScore = 70.0
    static let pointsPerStandardDeviation = 15.0

    /// typical score minus one standard deviation of the composite. The state
    /// compares the rounded score, so the line sits at a raw 54.5.
    static let lowRecoveryThreshold = typicalScore - pointsPerStandardDeviation

    static let baselineWindowDays = 30

    // fewer days than this and "normal" is too thin to measure against, so
    // that input sits out rather than swinging the score
    static let minimumBaselineDays = 7

    // one freak reading can move the score at most this far
    static let zScoreLimit = 3.0

    struct Input {
        let metric: AnalyticMetric
        let weight: Double
        let higherIsBetter: Bool
    }

    // HRV leads because it is the most direct read on recovery that a watch
    // gives. Resting heart rate and sleep share the rest.
    static let inputs: [Input] = [
        Input(metric: .quantity(.hrv), weight: 0.4, higherIsBetter: true),
        Input(metric: .quantity(.restingHeartRate), weight: 0.3, higherIsBetter: false),
        Input(metric: .sleepDuration, weight: 0.3, higherIsBetter: true),
    ]

    /// This morning's score, and how it moved since yesterday morning. nil
    /// when no input has a reading for its latest day plus enough history.
    static func readiness(
        history: HealthHistory,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> Readiness? {
        guard let today = score(history.series(asOf: now), asOf: now, calendar: calendar) else {
            return nil
        }

        var delta: Int?
        if let yesterdayMorning = calendar.date(byAdding: .day, value: -1, to: now),
           let yesterday = score(history.series(asOf: yesterdayMorning), asOf: yesterdayMorning, calendar: calendar) {
            delta = today.score - yesterday.score
        }

        return Readiness(
            day: calendar.startOfDay(for: now),
            score: today.score,
            delta: delta,
            inputsUsed: today.inputsUsed)
    }

    /// The last seven mornings, oldest first, ending today. A morning with no
    /// score stays in the list as nil, so the chart keeps its shape.
    static func week(
        history: HealthHistory,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [DayReadiness] {
        (0..<7).reversed().compactMap { daysAgo in
            guard let morning = calendar.date(byAdding: .day, value: -daysAgo, to: now) else {
                return nil
            }
            return DayReadiness(
                day: calendar.startOfDay(for: morning),
                score: score(history.series(asOf: morning), asOf: morning, calendar: calendar)?.score)
        }
    }

    private struct DayScore {
        let score: Int
        let inputsUsed: [AnalyticMetric]
    }

    // inputs with no reading or too little history sit out; the composite is
    // rescaled over whichever remain
    private static func score(
        _ seriesByMetric: [AnalyticMetric: [DatedValue]],
        asOf now: Date,
        calendar: Calendar
    ) -> DayScore? {
        var weightedSum = 0.0
        var sumOfSquaredWeights = 0.0
        var used: [AnalyticMetric] = []

        for input in inputs {
            guard let series = seriesByMetric[input.metric],
                  let z = zScore(of: input.metric, in: series, asOf: now, calendar: calendar) else {
                continue
            }
            let better = input.higherIsBetter ? z : -z
            weightedSum += input.weight * min(max(better, -zScoreLimit), zScoreLimit)
            sumOfSquaredWeights += input.weight * input.weight
            used.append(input.metric)
        }

        guard sumOfSquaredWeights > 0 else { return nil }
        let composite = weightedSum / sumOfSquaredWeights.squareRoot()
        let raw = typicalScore + pointsPerStandardDeviation * composite
        return DayScore(score: Int(min(max(raw, 0), 100).rounded()), inputsUsed: used)
    }

    // same measurement the anomaly detector makes: the judged day against the
    // days before it, never including itself
    private static func zScore(
        of metric: AnalyticMetric,
        in series: [DatedValue],
        asOf now: Date,
        calendar: Calendar
    ) -> Double? {
        let judgedDay = metric.latestCompleteDay(asOf: now, calendar: calendar)
        guard let current = series.first(where: { calendar.startOfDay(for: $0.day) == judgedDay })?.value,
              let baselineEnd = calendar.date(byAdding: .day, value: -1, to: judgedDay),
              let baseline = MetricBaseline.compute(
                over: series, windowDays: baselineWindowDays, endingOn: baselineEnd, calendar: calendar),
              baseline.sampleCount >= minimumBaselineDays,
              let spread = baseline.standardDeviation, spread > 0 else {
            return nil
        }
        return (current - baseline.mean) / spread
    }
}

/// One morning's readiness.
struct Readiness {
    let day: Date
    let score: Int

    /// points up or down on yesterday morning; nil when yesterday had no score
    let delta: Int?

    /// which inputs had enough data to count. Fewer than all three means a
    /// thinner read.
    let inputsUsed: [AnalyticMetric]

    var state: RecoveryState {
        Double(score) < ReadinessCalculator.lowRecoveryThreshold ? .lowRecovery : .recovered
    }
}

/// One bar in the week chart.
struct DayReadiness {
    let day: Date
    let score: Int?
}

/// The switch the whole Summary screen turns on: aurora hue, hero wording, and
/// which tiles get the attention treatment.
enum RecoveryState {
    case recovered
    case lowRecovery
}
