import Foundation
import Testing
@testable import Insights

/// The ranker against hand-built findings, so a change to any detector's maths
/// cannot quietly rewrite these tests.
@Suite struct FindingRankerTests {

    /// A finding with only the fields ranking reads worth setting; the rest is
    /// plausible filler.
    private func finding(
        _ type: Finding.FindingType,
        metric: AnalyticMetric,
        magnitude: Double,
        confidence: Double = 1,
        tone: Finding.Tone = .neutral,
        drivingMetric: AnalyticMetric? = nil
    ) -> Finding {
        Finding(
            type: type,
            metric: metric,
            drivingMetric: drivingMetric,
            magnitude: magnitude,
            currentValue: 50,
            baselineValue: 45,
            windowDays: 30,
            confidence: confidence,
            direction: .rising,
            tone: tone,
            meaning: "\(metric.displayName) moved.",
            plainStatement: "\(metric.displayName) moved.")
    }

    // the magnitude each stage refuses to emit below, so a finding built on one
    // of these has only just qualified
    private let qualifyingZScore = 1.5
    private let qualifyingRelativeChange = 0.05
    private let qualifyingCorrelation = 0.4

    @Test func findingsThatOnlyJustQualifyAreWorthTheSame() {
        // the point of the scale: 1.5 standard deviations, 5%, and an r of 0.4
        // all arrive worth exactly 1
        let anomaly = finding(.anomaly, metric: .quantity(.hrv), magnitude: qualifyingZScore)
        let trend = finding(.trend, metric: .sleepDuration, magnitude: qualifyingRelativeChange)
        let correlation = finding(
            .correlation, metric: .quantity(.vo2Max), magnitude: qualifyingCorrelation)

        #expect(FindingRanker.score(anomaly) == 1)
        #expect(FindingRanker.score(trend) == 1)
        #expect(FindingRanker.score(correlation) == 1)
    }

    @Test func strongerFindingsRankAbove() {
        // a trend 4x past its bar beats an anomaly barely over its own
        let ranked = FindingRanker.rank([
            finding(.anomaly, metric: .quantity(.hrv), magnitude: 1.6),
            finding(.trend, metric: .sleepDuration, magnitude: 0.2),
        ])
        #expect(ranked.map(\.metric) == [.sleepDuration, .quantity(.hrv)])
    }

    @Test func thinHistoryHoldsAFindingBackWithoutSilencingIt() {
        // same size of surprise, different depth of evidence behind it
        let wellEvidenced = finding(
            .anomaly, metric: .quantity(.hrv), magnitude: 2.0, confidence: 1)
        let barelyEvidenced = finding(
            .anomaly, metric: .sleepDuration, magnitude: 2.0, confidence: 0.2)

        #expect(FindingRanker.score(wellEvidenced) > FindingRanker.score(barelyEvidenced))
        // held back, never zeroed
        #expect(FindingRanker.score(barelyEvidenced) > 0.5 * FindingRanker.score(wellEvidenced))
    }

    @Test func warningEdgesOutEquallyStrongNeutralNews() {
        let ranked = FindingRanker.rank([
            finding(.anomaly, metric: .quantity(.steps), magnitude: 2.0, tone: .neutral),
            finding(.anomaly, metric: .quantity(.restingHeartRate),
                    magnitude: 2.0, tone: .cautionary),
        ])
        #expect(ranked.first?.metric == .quantity(.restingHeartRate))
    }

    @Test func clearlyStrongerNewsStillBeatsAFaintWarning() {
        // the tone nudge settles near-ties only; it cannot carry a weak finding
        // over a much stronger one
        let ranked = FindingRanker.rank([
            finding(.anomaly, metric: .quantity(.restingHeartRate),
                    magnitude: 1.6, tone: .cautionary),
            finding(.anomaly, metric: .quantity(.steps), magnitude: 4.0, tone: .neutral),
        ])
        #expect(ranked.first?.metric == .quantity(.steps))
    }

    @Test func extraStandardDeviationsKeepBuyingPositionButBuyLess() {
        // three times the bar, ten times it, and a reading only a broken sensor
        // produces — each still outranks the last
        let notable = finding(.anomaly, metric: .quantity(.hrv), magnitude: 4.5)
        let extreme = finding(.anomaly, metric: .quantity(.hrv), magnitude: 15.0)
        let implausible = finding(.anomaly, metric: .quantity(.hrv), magnitude: 150.0)

        #expect(FindingRanker.score(notable) < FindingRanker.score(extreme))
        #expect(FindingRanker.score(extreme) < FindingRanker.score(implausible))
    }

    @Test func oneExtremeReadingCannotRunAwayWithTheList() {
        // ten times the bar is worth well under twice what three times is, so a
        // freak reading leads without burying the rest of the day
        let notable = finding(.anomaly, metric: .quantity(.hrv), magnitude: 4.5)
        let extreme = finding(.anomaly, metric: .quantity(.hrv), magnitude: 15.0)

        #expect(FindingRanker.score(extreme) < 2 * FindingRanker.score(notable))
    }

    @Test func equalScoresAlwaysComeOutInTheSameOrder() {
        // three findings scoring exactly 1, fed in backwards
        let ranked = FindingRanker.rank([
            finding(.correlation, metric: .quantity(.hrv), magnitude: qualifyingCorrelation,
                    drivingMetric: .sleepDuration),
            finding(.trend, metric: .sleepDuration, magnitude: qualifyingRelativeChange),
            finding(.anomaly, metric: .quantity(.steps), magnitude: qualifyingZScore),
        ])
        #expect(ranked.map(\.type) == [.anomaly, .trend, .correlation])
    }

    @Test func orderDoesNotDependOnTheOrderFindingsArriveIn() {
        // detectors walk a dictionary, so their output order is not guaranteed
        // run to run; the ranked list has to be
        let day = [
            finding(.anomaly, metric: .quantity(.hrv), magnitude: 2.4, tone: .cautionary),
            finding(.trend, metric: .sleepDuration, magnitude: 0.12),
            finding(.correlation, metric: .quantity(.vo2Max), magnitude: 0.7,
                    drivingMetric: .quantity(.activeEnergy)),
            finding(.anomaly, metric: .quantity(.steps), magnitude: 1.9, confidence: 0.6),
            finding(.trend, metric: .quantity(.restingHeartRate), magnitude: 0.08,
                    tone: .cautionary),
        ]
        let forwards = FindingRanker.rank(day).map(\.metric)
        let backwards = FindingRanker.rank(day.reversed()).map(\.metric)
        #expect(forwards == backwards)
    }

    @Test func everyMetricIsHeardBeforeAnyMetricSpeaksTwice() {
        // HRV owns the five highest scores; sleep, scoring lowest of all, still
        // makes the list
        var day = (0..<5).map { index in
            finding(.anomaly, metric: .quantity(.hrv), magnitude: 4.0 - Double(index) * 0.1)
        }
        day.append(finding(.trend, metric: .sleepDuration, magnitude: 0.06))

        let ranked = FindingRanker.rank(day)
        #expect(ranked.count == 5)
        #expect(ranked.contains { $0.metric == .sleepDuration })
        #expect(ranked.filter { $0.metric == .quantity(.hrv) }.count == 4)
    }

    @Test func leftoverSlotsGoToTheStrongestOfWhatWasPassedOver() {
        // a quiet day with two metrics talking: nothing is dropped, and repeats
        // come back in score order rather than arrival order
        let ranked = FindingRanker.rank([
            finding(.anomaly, metric: .quantity(.hrv), magnitude: 3.0),
            finding(.trend, metric: .quantity(.hrv), magnitude: 0.1),
            finding(.correlation, metric: .quantity(.hrv), magnitude: 0.6,
                    drivingMetric: .sleepDuration),
            finding(.anomaly, metric: .sleepDuration, magnitude: 1.8),
        ])
        #expect(ranked.count == 4)
        #expect(ranked.map(\.type) == [.anomaly, .trend, .correlation, .anomaly])
    }

    @Test func theListIsCutToFive() {
        let day = (0..<8).map { index in
            finding(.anomaly, metric: .quantity(MetricKind.allCases[index]),
                    magnitude: 2.0 + Double(index) * 0.1)
        }
        #expect(FindingRanker.rank(day).count == 5)
    }

    @Test func aQuietDayRanksToNothing() {
        #expect(FindingRanker.rank([]).isEmpty)
    }
}
