import Foundation
import Testing
@testable import Insights

/// The readiness card's words: right headline for the state, grammar that
/// fits however many inputs counted, and no advice.
@Suite struct HeroCopyTests {

    private let allInputs: [AnalyticMetric] = [.quantity(.hrv), .quantity(.restingHeartRate), .sleepDuration]

    private func readiness(_ score: Int, inputs: [AnalyticMetric]? = nil) -> Readiness {
        Readiness(day: .now, score: score, delta: nil, inputsUsed: inputs ?? allInputs)
    }

    @Test func noScoreExplainsTheBaselineIsBuilding() {
        #expect(HeroCopy.copy(for: nil).headline == "Building your baseline")
    }

    @Test func lowRecoveryReadsSoftlyAndNamesTheInputs() {
        let copy = HeroCopy.copy(for: readiness(44))
        #expect(copy.headline == "Recovery is running low")
        #expect(copy.explanation
            == "Taken together, your HRV, resting heart rate and sleep are less favourable than your usual for the last 30 days.")
    }

    @Test func anOrdinaryMorningIsInLine() {
        let copy = HeroCopy.copy(for: readiness(70))
        #expect(copy.headline == "Recovered")
        #expect(copy.explanation
            == "Taken together, your HRV, resting heart rate and sleep are in line with your last 30 days.")
    }

    @Test func oneStandardDeviationAboveNormalIsWellRecovered() {
        // 70 + 15 = 85 is the mirror of the low line at 55
        #expect(HeroCopy.copy(for: readiness(85)).headline == "Well recovered")
        #expect(HeroCopy.copy(for: readiness(84)).headline == "Recovered")
    }

    @Test func oneInputReadsAsSingular() {
        let copy = HeroCopy.copy(for: readiness(70, inputs: [.sleepDuration]))
        #expect(copy.explanation == "Your sleep is in line with your last 30 days.")

        let low = HeroCopy.copy(for: readiness(50, inputs: [.quantity(.hrv)]))
        #expect(low.explanation == "Your HRV is less favourable than your usual for the last 30 days.")
    }

    @Test func restingHeartRateIsNeverSaidToBeBelowUsualWhenItIsHigh() {
        // a high resting heart rate is what lowers the score, so the copy
        // must not describe it as sitting below anything
        let low = HeroCopy.copy(for: readiness(50, inputs: [.quantity(.restingHeartRate)]))
        #expect(low.explanation == "Your resting heart rate is less favourable than your usual for the last 30 days.")
        #expect(!low.explanation.contains("below"))
        #expect(!low.explanation.contains("above"))
    }

    @Test func deltasReadPlainly() {
        #expect(HeroCopy.delta(4) == "+4 since yesterday")
        #expect(HeroCopy.delta(-3) == "−3 since yesterday")
        #expect(HeroCopy.delta(0) == "Same as yesterday")
        #expect(HeroCopy.delta(nil) == nil)
    }

    @Test func listsJoinNaturally() {
        #expect(HeroCopy.listed(["a"]) == "a")
        #expect(HeroCopy.listed(["a", "b"]) == "a and b")
        #expect(HeroCopy.listed(["a", "b", "c"]) == "a, b and c")
    }
}
