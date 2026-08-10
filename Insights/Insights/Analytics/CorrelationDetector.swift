import Foundation

/// Answers "what tends to move this?".
///
/// The other detectors look at one metric at a time. This one checks pairs,
/// such as "longer sleep, higher HRV", against the user's own history, and
/// keeps only the pairings that hold up.
enum CorrelationDetector {
    /// How tightly two metrics must move together before the link is worth
    /// reporting, as a Pearson r (0 is unrelated, 1 is perfect lockstep).
    /// The one sensitivity knob.
    static let correlationThreshold = 0.4

    /// Fewest day pairs a reported link may rest on. Below this even a tight r
    /// is mostly luck, so the pairing stays quiet however good it looks.
    static let minimumPairCount = 14

    /// Days of history pairs are drawn from.
    static let windowDays = 90

    /// How many pairs a link needs to count as fully evidenced. Well under the
    /// 90-day window on purpose: both metrics have to be recorded on the same
    /// day, and real history rarely offers 90 of those.
    static let pairsForFullConfidence = 45

    /// One relationship worth checking. Written by hand rather than generated
    /// from every possible pairing, because testing everything against
    /// everything surfaces coincidences at this threshold.
    struct Hypothesis {
        let driver: AnalyticMetric
        let outcome: AnalyticMetric
        /// Days between a driver reading and the outcome it pairs with. Sleep
        /// is filed under the morning it ended, so a night and the day it leads
        /// into already share a date. Only a real overnight gap needs 1.
        let lagDays: Int
        /// The driver being higher, worded to read after both "on days with"
        /// and "the day after".
        let higherDriverPhrase: String
    }

    /// The relationships worth looking for. Active energy stands in for
    /// training load, since workouts are not read from Apple Health yet.
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

    /// Checks every hypothesis and returns a Finding for each that clears both
    /// minimums. One whose two metrics barely overlap produces nothing.
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
        // FindingRanker sorts properly later. Alphabetical keeps the output the
        // same from run to run, with the driver breaking ties between
        // hypotheses that share an outcome.
        return findings.sorted {
            ($0.metric.displayName, $0.drivingMetric?.displayName ?? "")
                < ($1.metric.displayName, $1.drivingMetric?.displayName ?? "")
        }
    }

    /// Pairs up one hypothesis' two series and reports it only if the link is
    /// both tight enough and built on enough days.
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

    /// Pairs each outcome day with the driver reading from `lagDays` earlier,
    /// keeping only days where both sides have data. The window hangs off the
    /// outcome, so a driver day just before the window still counts.
    private static func dayPairs(
        for hypothesis: Hypothesis,
        driverSeries: [DatedValue],
        outcomeSeries: [DatedValue],
        asOf now: Date,
        calendar: Calendar
    ) -> [DayPair] {
        let windowEnd = hypothesis.outcome.latestCompleteDay(asOf: now, calendar: calendar)
        guard let windowStart = calendar.date(
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

    /// Pearson r: how much the two move together, divided by how much each
    /// moves on its own. The units cancel out, so the answer is always -1 to 1
    /// and comparable across metrics. nil when either side is flat.
    private static func pearsonCorrelation(of pairs: [DayPair]) -> Double? {
        let count = Double(pairs.count)
        guard count >= 2 else { return nil }

        let meanDriver = pairs.reduce(0) { $0 + $1.driverValue } / count
        let meanOutcome = pairs.reduce(0) { $0 + $1.outcomeValue } / count

        var crossDeviation = 0.0     // sum of (x - meanX)(y - meanY)
        var driverVariation = 0.0    // sum of (x - meanX) squared
        var outcomeVariation = 0.0   // sum of (y - meanY) squared
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

    /// Packs a surviving link into a Finding. Direction is what the outcome
    /// does when the driver goes up, so a negative r reads as falling.
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
            // no single day is under judgement here, so these describe the
            // outcome across all the paired days
            currentValue: latestOutcomeValue ?? meanOutcomeValue,
            baselineValue: meanOutcomeValue,
            windowDays: windowDays,
            confidence: min(1, Double(pairs.count) / Double(pairsForFullConfidence)),
            direction: direction,
            // a relationship is a lever, not news. Nothing has happened yet, so
            // calling it good or bad would overclaim.
            tone: .neutral,
            meaning: "\(outcomeName) tends to be \(higherOrLower) \(whenPhrase). "
                + "Across \(pairs.count) day pairs from the past \(windowDays) days "
                + "the relationship holds at r = \(formatted(correlation)).",
            plainStatement: "\(outcomeName) tends to be \(higherOrLower) \(whenPhrase).")
    }

    /// How the timing reads in a sentence, so a same-day link is never worded
    /// as if one day followed the other.
    private static func lagPhrase(forLagDays lagDays: Int) -> String {
        switch lagDays {
        case 0: "on days with"
        case 1: "the day after"
        default: "\(lagDays) days after"
        }
    }

    /// Two decimals only. A third would claim more precision than a few dozen
    /// day pairs can support.
    private static func formatted(_ correlation: Double) -> String {
        String(format: "%.2f", correlation)
    }
}
