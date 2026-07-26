import Foundation

/// Fourth stage of the engine, and the first to relate two metrics rather than
/// judging one against itself: it tests a fixed list of hypotheses across day
/// pairs and reports only the ones that hold up in this user's own history.
enum CorrelationDetector {
    /// How strong a Pearson r must be before a pairing is worth reporting.
    /// The single sensitivity knob.
    static let correlationThreshold = 0.4

    /// Fewest day pairs a reported correlation may rest on. Below this a strong
    /// r is mostly luck, so the pairing stays silent however tight it looks.
    static let minimumPairCount = 14

    /// Days of history pairs are drawn from.
    static let windowDays = 90

    /// One relationship the engine looks for. Hypotheses are written down rather
    /// than generated from every metric pairing: testing everything against
    /// everything would turn up coincidences at this threshold, and a named
    /// hypothesis can be phrased for the user in a way a generated one cannot.
    struct Hypothesis {
        /// The metric whose movement may lead the outcome.
        let driver: AnalyticMetric
        /// The metric whose state the user cares about.
        let outcome: AnalyticMetric
        /// Days between a driver reading and the outcome day it pairs with.
        /// Sleep series are keyed to the morning woken, so a night's sleep and
        /// the day it leads into already share a day — those pairings use 0,
        /// and only a genuine overnight gap needs 1.
        let lagDays: Int
        /// The driver being higher, worded to read after both "on days with"
        /// and "the day after".
        let higherDriverPhrase: String
    }

    /// The relationships worth looking for. Activity stands in for training
    /// load until workouts are read from HealthKit.
    static let hypotheses: [Hypothesis] = [
        Hypothesis(
            driver: .sleepDuration,
            outcome: .quantity(.hrv),
            lagDays: 0,
            higherDriverPhrase: "a longer night's sleep"),
        Hypothesis(
            driver: .quantity(.activeEnergy),
            outcome: .deepSleepDuration,
            lagDays: 1,
            higherDriverPhrase: "more activity than usual"),
        Hypothesis(
            driver: .quantity(.restingHeartRate),
            outcome: .quantity(.hrv),
            lagDays: 0,
            higherDriverPhrase: "a higher resting heart rate"),
    ]

    /// Tests every hypothesis against the cached history and returns a Finding
    /// for each one that clears both minimums. A hypothesis whose metrics have
    /// too little overlapping history simply produces nothing.
    static func detect(
        metrics: [DailyMetricRecord],
        nights: [SleepNightRecord],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Finding] {
        let seriesByMetric = BaselineBuilder.dailySeries(
            metrics: metrics, nights: nights, asOf: now)

        var findings: [Finding] = []
        for hypothesis in hypotheses {
            guard let driverSeries = seriesByMetric[hypothesis.driver],
                  let outcomeSeries = seriesByMetric[hypothesis.outcome] else {
                continue
            }
            if let finding = finding(
                for: hypothesis,
                driverSeries: driverSeries,
                outcomeSeries: outcomeSeries,
                asOf: now,
                calendar: calendar) {
                findings.append(finding)
            }
        }
        // ranking comes later in the pipeline; alphabetical keeps output stable,
        // with the driver breaking ties between hypotheses sharing an outcome
        return findings.sorted {
            ($0.metric.displayName, $0.drivingMetric?.displayName ?? "")
                < ($1.metric.displayName, $1.drivingMetric?.displayName ?? "")
        }
    }

    /// Pairs one hypothesis' two series and reports it if the correlation is
    /// both strong enough and built on enough days. nil whenever either
    /// minimum fails, or either side of the pairs never varies.
    private static func finding(
        for hypothesis: Hypothesis,
        driverSeries: [DatedValue],
        outcomeSeries: [DatedValue],
        asOf now: Date,
        calendar: Calendar
    ) -> Finding? {
        let pairs = dayPairs(
            for: hypothesis,
            driverSeries: driverSeries,
            outcomeSeries: outcomeSeries,
            asOf: now,
            calendar: calendar)

        guard pairs.count >= minimumPairCount,
              let correlation = pearsonCorrelation(of: pairs),
              abs(correlation) >= correlationThreshold else {
            return nil
        }
        return makeFinding(for: hypothesis, pairs: pairs, correlation: correlation)
    }

    /// One day's driver value alongside the outcome value it is paired with.
    private struct DayPair {
        let outcomeDay: Date
        let driverValue: Double
        let outcomeValue: Double
    }

    /// Walks the outcome's days inside the window and pairs each with the driver
    /// value `lagDays` earlier, keeping only days where both sides have a
    /// reading. The window is anchored on the outcome because the outcome is
    /// what is being explained, and its own completeness rule decides how
    /// recent a day may be — a driver day just before the window still counts.
    private static func dayPairs(
        for hypothesis: Hypothesis,
        driverSeries: [DatedValue],
        outcomeSeries: [DatedValue],
        asOf now: Date,
        calendar: Calendar
    ) -> [DayPair] {
        guard let windowEnd = latestCompleteDay(
            for: hypothesis.outcome, asOf: now, calendar: calendar),
              let windowStart = calendar.date(
                byAdding: .day, value: -(windowDays - 1), to: windowEnd) else {
            return []
        }

        let driverValueByDay = Dictionary(
            driverSeries.map { (calendar.startOfDay(for: $0.day), $0.value) },
            uniquingKeysWith: { first, _ in first })

        var pairs: [DayPair] = []
        for dated in outcomeSeries {
            let outcomeDay = calendar.startOfDay(for: dated.day)
            guard outcomeDay >= windowStart, outcomeDay <= windowEnd,
                  let driverDay = calendar.date(
                    byAdding: .day, value: -hypothesis.lagDays, to: outcomeDay),
                  let driverValue = driverValueByDay[driverDay] else {
                continue
            }
            pairs.append(DayPair(
                outcomeDay: outcomeDay,
                driverValue: driverValue,
                outcomeValue: dated.value))
        }
        return pairs
    }

    /// The most recent day this metric can be judged on: yesterday for
    /// quantities, since today is still accumulating, and today for sleep,
    /// which is keyed to the morning woken.
    private static func latestCompleteDay(
        for metric: AnalyticMetric,
        asOf now: Date,
        calendar: Calendar
    ) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch metric {
        case .quantity:
            return calendar.date(byAdding: .day, value: -1, to: today)
        case .sleepDuration, .deepSleepDuration, .remSleepDuration:
            return today
        }
    }

    /// Pearson r over the pairs: covariance divided by the two spreads, giving a
    /// unitless -1…1 that compares metrics in different units. nil when either
    /// side is flat, since a series that never moves cannot move with anything.
    private static func pearsonCorrelation(of pairs: [DayPair]) -> Double? {
        let count = Double(pairs.count)
        guard count >= 2 else { return nil }

        let meanDriver = pairs.reduce(0) { $0 + $1.driverValue } / count
        let meanOutcome = pairs.reduce(0) { $0 + $1.outcomeValue } / count

        var crossDeviation = 0.0     // Σ (x − x̄)(y − ȳ)
        var driverVariation = 0.0    // Σ (x − x̄)²
        var outcomeVariation = 0.0   // Σ (y − ȳ)²
        for pair in pairs {
            let driverDeviation = pair.driverValue - meanDriver
            let outcomeDeviation = pair.outcomeValue - meanOutcome
            crossDeviation += driverDeviation * outcomeDeviation
            driverVariation += driverDeviation * driverDeviation
            outcomeVariation += outcomeDeviation * outcomeDeviation
        }

        guard driverVariation > 0, outcomeVariation > 0 else { return nil }
        return crossDeviation / (driverVariation * outcomeVariation).squareRoot()
    }

    /// Turns a qualifying correlation into a narratable Finding. Direction is
    /// how the outcome responds when the driver rises, so a negative r reads as
    /// falling.
    private static func makeFinding(
        for hypothesis: Hypothesis,
        pairs: [DayPair],
        correlation: Double
    ) -> Finding {
        let direction: Finding.Direction = correlation > 0 ? .rising : .falling
        let higherOrLower = direction == .rising ? "higher" : "lower"
        let outcomeName = hypothesis.outcome.displayName
        let whenPhrase = "\(lagPhrase(forLagDays: hypothesis.lagDays)) "
            + hypothesis.higherDriverPhrase
        let latestOutcomeValue = pairs.max(by: { $0.outcomeDay < $1.outcomeDay })?.outcomeValue
        let meanOutcomeValue = pairs.reduce(0) { $0 + $1.outcomeValue } / Double(pairs.count)

        return Finding(
            type: .correlation,
            metric: hypothesis.outcome,
            drivingMetric: hypothesis.driver,
            magnitude: abs(correlation),
            // a correlation has no single judged value, so these describe the
            // outcome across the paired days rather than one day's reading
            currentValue: latestOutcomeValue ?? meanOutcomeValue,
            baselineValue: meanOutcomeValue,
            windowDays: windowDays,
            confidence: Double(pairs.count) / Double(windowDays),
            direction: direction,
            // a relationship is a lever, not news — nothing has happened yet,
            // so calling it good or bad would overclaim
            tone: .neutral,
            meaning: "\(outcomeName) tends to be \(higherOrLower) \(whenPhrase). "
                + "Across \(pairs.count) day pairs from the past \(windowDays) days "
                + "the relationship holds at r = \(formatted(correlation)).",
            plainStatement: "\(outcomeName) tends to be \(higherOrLower) \(whenPhrase).")
    }

    /// How the pairing's timing reads in a sentence, so a same-day relationship
    /// is never described as if one day followed the other.
    private static func lagPhrase(forLagDays lagDays: Int) -> String {
        switch lagDays {
        case 0: "on days with"
        case 1: "the day after"
        default: "\(lagDays) days after"
        }
    }

    /// Correlations are reported to two decimals — a third would imply more
    /// precision than a few dozen day pairs support.
    private static func formatted(_ correlation: Double) -> String {
        String(format: "%.2f", correlation)
    }
}
