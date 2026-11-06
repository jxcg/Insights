import Foundation
import Testing
@testable import Insights

/// A narrator that says whatever the test needs, or fails on cue.
private struct ScriptedNarrator: Narrator {
    enum Failure: Error { case modelRefused }

    // nil entry means "throw" for that finding
    let drafts: [String: NarrationDraft?]

    func draft(for finding: Finding) async throws -> NarrationDraft {
        guard let scripted = drafts[finding.plainStatement], let draft = scripted else {
            throw Failure.modelRefused
        }
        return draft
    }
}

/// Counts how often it is asked, and always refuses.
private final class CountingNarrator: Narrator {
    private(set) var calls = 0

    func draft(for finding: Finding) async throws -> NarrationDraft {
        calls += 1
        throw ScriptedNarrator.Failure.modelRefused
    }
}

/// Ignores cancellation and never answers blocked findings until test cleanup.
private final class SuspendedNarrator: Narrator {
    let blockedStatements: Set<String>
    var onStart: (() -> Void)?
    var responseDelay: Duration = .zero
    private var pending: [CheckedContinuation<NarrationDraft, Never>] = []
    private(set) var released = false

    init(blockedStatements: Set<String>) {
        self.blockedStatements = blockedStatements
    }

    func draft(for finding: Finding) async throws -> NarrationDraft {
        if blockedStatements.contains(finding.plainStatement), !released {
            return await withCheckedContinuation { continuation in
                pending.append(continuation)
                onStart?()
            }
        }
        try await Task.sleep(for: responseDelay)
        return response
    }

    func release() {
        released = true
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: response) }
    }

    private var response: NarrationDraft {
        NarrationDraft(sentence: "Your resting heart rate was 62 bpm, above 54 bpm.", tone: .cautionary)
    }
}

private func finding(
    _ type: Finding.FindingType = .anomaly,
    metric: AnalyticMetric = .quantity(.restingHeartRate),
    direction: Finding.Direction = .rising,
    tone: Finding.Tone = .cautionary,
    meaning: String = "Resting heart rate yesterday sat well above its usual range: 62 bpm against a typical 54 bpm.",
    plainStatement: String = "Resting heart rate yesterday was 62 bpm, well above its usual 54 bpm."
) -> Finding {
    Finding(
        type: type, metric: metric, drivingMetric: nil, magnitude: 2, currentValue: 62,
        baselineValue: 54, windowDays: 30, confidence: 1, direction: direction, tone: tone,
        meaning: meaning, plainStatement: plainStatement)
}

/// What reaches the screen: the model's sentence when it passes, the engine's
/// own sentence in every other case.
@Suite struct InsightGeneratorTests {

    @Test func withNoModelEveryInsightIsTheTemplate() async {
        let findings = [finding(), finding(plainStatement: "Steps were low.")]
        let digest = await InsightGenerator(narrator: nil).narrate(findings)

        #expect(digest.insights.map(\.sentence) == findings.map(\.plainStatement))
        #expect(digest.insights.allSatisfy { $0.source == .template })
    }

    @Test func aGoodDraftIsUsed() async {
        let resting = finding()
        let narrator = ScriptedNarrator(drafts: [
            resting.plainStatement: NarrationDraft(
                sentence: "Your resting heart rate was 62 bpm yesterday, above your usual 54 bpm.",
                tone: .cautionary),
        ])
        let digest = await InsightGenerator(narrator: narrator).narrate([resting])

        #expect(digest.insights.first?.source == .model)
        #expect(digest.insights.first?.sentence
            == "Your resting heart rate was 62 bpm yesterday, above your usual 54 bpm.")
    }

    @Test func aFailingModelFallsBackForThatFindingOnly() async {
        let first = finding()
        let second = finding(plainStatement: "Resting heart rate was 62 bpm against 54 bpm.")
        let narrator = ScriptedNarrator(drafts: [
            first.plainStatement: nil,
            second.plainStatement: NarrationDraft(
                sentence: "Your resting heart rate was 62 bpm, above 54 bpm.", tone: .cautionary),
        ])
        let digest = await InsightGenerator(narrator: narrator).narrate([first, second])

        #expect(digest.insights.map(\.source) == [.template, .model])
        #expect(digest.insights.first?.sentence == first.plainStatement)
    }

    @Test(arguments: [1, 2])
    func stuckRequestsTimeOutAndLaterFindingsAreNarrated(stuckCount: Int) async {
        let blocked = ["First", "Second"].prefix(stuckCount).map {
            finding(plainStatement: "\($0): Resting heart rate was 62 bpm against 54 bpm.")
        }
        let link = finding(.correlation)
        let findings = blocked + [link, finding()]
        let narrator = SuspendedNarrator(blockedStatements: Set(blocked.map(\.plainStatement)))
        narrator.responseDelay = .milliseconds(20)
        // Independent cleanup also lets a broken implementation fail instead
        // of leaving the test process suspended forever. Other suites share
        // the main actor, so elapsed wall time includes their synchronous work;
        // completion before this rescue, not a tight timing ceiling, is the
        // timeout contract checked here.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            narrator.release()
        }
        defer { watchdog.cancel(); narrator.release() }

        let digest = await InsightGenerator(narrator: narrator, requestTimeout: .seconds(1)).narrate(findings)
        #expect(!narrator.released)
        #expect(digest.insights.map(\.finding.plainStatement) == findings.map(\.plainStatement))
        #expect(digest.insights.dropLast().allSatisfy { $0.source == .template })
        #expect(digest.insights.dropLast().map(\.sentence) == findings.dropLast().map(\.plainStatement))
        #expect(digest.insights.last?.source == .model)
    }

    @Test func cancellingAStuckRequestReturnsWithoutWaitingForItsDeadline() async {
        let first = finding()
        let findings = [first, finding(plainStatement: "Later finding.")]
        let narrator = SuspendedNarrator(blockedStatements: [first.plainStatement])
        let (started, continuation) = AsyncStream<Void>.makeStream()
        narrator.onStart = { continuation.yield(()); continuation.finish() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            narrator.release()
            continuation.finish()
        }
        defer { watchdog.cancel(); narrator.release() }

        let task = Task {
            await InsightGenerator(narrator: narrator, requestTimeout: .seconds(60)).narrate(findings)
        }
        defer { task.cancel() }
        var didStart = false
        for await _ in started { didStart = true; break }
        #expect(didStart)
        task.cancel()
        let digest = await task.value

        #expect(!narrator.released)
        #expect(digest.insights.map(\.sentence) == findings.map(\.plainStatement))
        #expect(digest.insights.allSatisfy { $0.source == .template })
    }

    @Test func cancellationBeforeStartingUsesOnlyTemplates() async {
        let narrator = CountingNarrator()
        let findings = [finding()]
        let task = Task { await InsightGenerator(narrator: narrator).narrate(findings) }
        task.cancel()
        let digest = await task.value

        #expect(narrator.calls == 0)
        #expect(digest.insights.map(\.sentence) == findings.map(\.plainStatement))
        #expect(digest.insights.allSatisfy { $0.source == .template })
    }

    @Test func orderIsKept() async {
        let findings = (1...5).map { finding(plainStatement: "Finding \($0).") }
        let digest = await InsightGenerator(narrator: ScriptedNarrator(drafts: [:])).narrate(findings)

        #expect(digest.insights.map(\.finding.plainStatement) == findings.map(\.plainStatement))
    }

    @Test func correlationsNeverReachTheModel() async {
        let link = finding(.correlation, metric: .quantity(.hrv), direction: .falling, tone: .neutral)
        let narrator = CountingNarrator()
        let digest = await InsightGenerator(narrator: narrator).narrate([link])

        #expect(narrator.calls == 0)
        #expect(digest.insights.first?.source == .template)
    }

    @Test func theTemplateDigestNeedsNoModel() {
        let findings = [finding()]
        let digest = InsightGenerator.templateDigest(for: findings)
        #expect(digest.insights.map(\.sentence) == [findings[0].plainStatement])
    }
}

/// The rules a draft must pass. Each test breaks exactly one.
@Suite struct NarrationCheckTests {
    private let resting = finding()

    private let link = finding(
        .correlation, metric: .quantity(.hrv), direction: .falling, tone: .neutral,
        meaning: "HRV (SDNN) tends to be lower on days with a higher resting heart rate. Across 40 day pairs from the past 90 days the relationship holds at r = -0.52.",
        plainStatement: "HRV (SDNN) tends to be lower on days with a higher resting heart rate.")

    private func check(_ sentence: String, tone: Finding.Tone = .cautionary, for target: Finding? = nil) -> String? {
        NarrationCheck.accepted(NarrationDraft(sentence: sentence, tone: tone), for: target ?? resting)
    }

    @Test func aFaithfulRewordingPasses() {
        #expect(check("Your resting heart rate was 62 bpm yesterday, above your usual 54 bpm.") != nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(check("  Your resting heart rate was 62 bpm, above 54 bpm.\n")
            == "Your resting heart rate was 62 bpm, above 54 bpm.")
    }

    @Test func aChangedToneFails() {
        // told cautionary, came back positive: the model drifted
        #expect(check("Your resting heart rate was 62 bpm, above 54 bpm.", tone: .positive) == nil)
    }

    @Test func anInventedNumberFails() {
        #expect(check("Your resting heart rate was 62 bpm, about 15% above your usual 54 bpm.") == nil)
    }

    @Test func aRoundedNumberFails() {
        let sleep = finding(
            metric: .sleepDuration, direction: .falling,
            meaning: "Sleep duration last night sat well below its usual range: 5.6 h against a typical 7.4 h.",
            plainStatement: "Sleep duration last night was 5.6 h, well below its usual 7.4 h.")
        #expect(check("You slept about 6 hours last night, below your usual 7.4 h.", for: sleep) == nil)
    }

    @Test func thousandsSeparatorsMatchPlainNumbers() {
        let steps = finding(
            metric: .quantity(.steps), direction: .falling, tone: .neutral,
            meaning: "Steps yesterday sat well below its usual range: 3100 steps against a typical 8640 steps.",
            plainStatement: "Steps yesterday was 3100 steps, well below its usual 8640 steps.")
        #expect(check("You took 3,100 steps yesterday, below your usual 8,640 steps.", tone: .neutral, for: steps) != nil)
    }

    @Test func adviceFails() {
        #expect(check("Your resting heart rate was 62 bpm, so you should rest today.") == nil)
        #expect(check("Your resting heart rate was 62 bpm; consider seeing a doctor.") == nil)
    }

    @Test func cheerOnAWarningFails() {
        #expect(check("Your resting heart rate hit 62 bpm!") == nil)
        #expect(check("Great news, your resting heart rate was 62 bpm.") == nil)
    }

    @Test func twoSentencesFail() {
        #expect(check("Your resting heart rate was 62 bpm. That is above 54 bpm.") == nil)
    }

    @Test func aQuestionFails() {
        #expect(check("Did you notice your resting heart rate was 62 bpm?") == nil)
    }

    @Test func aContradictedDirectionFails() {
        // the finding rose; the draft says it fell
        #expect(check("Your resting heart rate dropped to 62 bpm from 54 bpm.") == nil)
    }

    @Test func correlationsAreNeverReworded() {
        // even a faithful rewording is refused: a flipped "higher" or "lower"
        // would invert the only fact the sentence carries
        #expect(check("Your HRV tends to be lower on days your resting heart rate is higher.", tone: .neutral, for: link) == nil)
        #expect(!NarrationCheck.isNarratable(link))
    }

    @Test func swappedNumbersFail() {
        #expect(check("Your resting heart rate was 54 bpm, above your usual 62 bpm.") == nil)
    }

    @Test func aDroppedNumberFails() {
        // only 62 left, now passed off as the usual
        #expect(check("Your resting heart rate rose above its usual 62 bpm.") == nil)
    }

    @Test func aNumberWithTheWrongUnitFails() {
        let trend = finding(
            .trend, direction: .rising,
            meaning: "Resting heart rate has risen about 8% over the past 21 days, now around 58 bpm against a 21-day average of 55.5 bpm.",
            plainStatement: "Resting heart rate has been trending up over the past 21 days, about 8% higher.")
        // 21 and 8 are both real, but 21 was days and 8 was a percentage
        #expect(check("Your resting heart rate rose 21% over 8 days.", for: trend) == nil)
        #expect(check("Your resting heart rate has risen about 8% over the past 21 days.", for: trend) != nil)
    }

    @Test func aNegationFails() {
        #expect(check("Your resting heart rate was 62 bpm, not above your usual 54 bpm.") == nil)
        // numbers, order and direction all fine; only the "n't" fails it
        #expect(check("Your resting heart rate was 62 bpm, which isn't within your usual 54 bpm.") == nil)
    }

    @Test func anInventedCauseFails() {
        #expect(check("Your resting heart rate was 62 bpm, likely due to stress.") == nil)
    }

    @Test func numbersInWordsFail() {
        #expect(check("Your resting heart rate was nearly double your usual 54 bpm.") == nil)
    }

    @Test func theWrongMetricFails() {
        // a resting heart rate finding described as plain heart rate
        #expect(check("Your heart rate was 62 bpm, above your usual 54 bpm.") == nil)
    }

    @Test func lessCommonDirectionWordsAreCaught() {
        #expect(check("Your resting heart rate dipped to 62 bpm from 54 bpm.") == nil)
    }

    @Test func anOverlongDraftFails() {
        let rambling = "Your resting heart rate was 62 bpm, above 54 bpm, "
            + String(repeating: "and that is the reading ", count: 10) + "."
        #expect(check(rambling) == nil)
    }

    @Test func anEmptyDraftFails() {
        #expect(check("   ") == nil)
    }

    // a model that copies the engine word for word must pass, or every
    // faithful draft would be thrown away
    @Test func theEnginesOwnSentencesPassTheirOwnCheck() {
        let engineSentences: [Finding] = [
            finding(),
            finding(
                metric: .sleepDuration, direction: .falling,
                meaning: "Sleep duration last night sat well below its usual range: 5.6 h against a typical 7.4 h.",
                plainStatement: "Sleep duration last night was 5.6 h, well below its usual 7.4 h."),
            finding(
                .trend, metric: .quantity(.restingHeartRate), direction: .rising,
                meaning: "Resting heart rate has risen about 8% over the past 21 days, now around 58 bpm against a 21-day average of 55.5 bpm.",
                plainStatement: "Resting heart rate has been trending up over the past 21 days, about 8% higher."),
            finding(
                .trend, metric: .quantity(.steps), direction: .falling,
                meaning: "Steps has fallen about 12% over the past 90 days, now around 7400 steps against a 90-day average of 8100 steps.",
                plainStatement: "Steps has been trending down over the past 90 days, about 12% lower."),
        ]
        for target in engineSentences {
            #expect(check(target.plainStatement, tone: target.tone, for: target) == target.plainStatement)
        }
    }

    @Test func quantitiesAreReadWithTheirUnits() {
        let read = NarrationCheck.quantities(in: "8,640 steps, 7.5 h, about 8%, r = 0.52, 30-day.")
        #expect(read.map(\.number) == ["8640", "7.5", "8", "0.52", "30"])
        #expect(read.map(\.unit) == ["step", "h", "%", "", "day"])
        // a subscript in "VO₂ max" is not a reading
        #expect(NarrationCheck.quantities(in: "VO₂ max").isEmpty)
    }

    @Test func everyMetricsOwnSentenceShapePasses() {
        // the anomaly sentence shape for every metric, with its real units
        let shapes: [(AnalyticMetric, String)] = [
            (.quantity(.heartRate), "Heart rate yesterday was 72 bpm, well above its usual 64.3 bpm."),
            (.quantity(.hrv), "HRV (SDNN) yesterday was 72 ms, well above its usual 64.3 ms."),
            (.quantity(.vo2Max), "VO₂ max yesterday was 72 ml/kg·min, well above its usual 64.3 ml/kg·min."),
            (.quantity(.respiratoryRate), "Respiratory rate yesterday was 17.2 breaths/min, well above its usual 14.5 breaths/min."),
            (.quantity(.wristTemperature), "Wrist temperature yesterday was 36.4 °C, well above its usual 35.6 °C."),
            (.quantity(.basalEnergy), "Resting energy yesterday was 2100 kcal, well above its usual 1950.5 kcal."),
            (.quantity(.activeEnergy), "Active energy yesterday was 720 kcal, well above its usual 520.5 kcal."),
            (.deepSleepDuration, "Deep sleep last night was 1.9 h, well above its usual 1.3 h."),
            (.remSleepDuration, "REM sleep last night was 2.1 h, well above its usual 1.6 h."),
        ]
        for (metric, sentence) in shapes {
            let target = finding(metric: metric, direction: .rising, tone: .neutral, meaning: sentence, plainStatement: sentence)
            #expect(check(sentence, tone: .neutral, for: target) == sentence)
        }
    }

    @Test func thePromptCarriesTheEnginesFactsAndTone() {
        let prompt = NarrationCheck.prompt(for: resting)
        #expect(prompt.contains(resting.meaning))
        #expect(prompt.contains("Tone: cautionary"))
        #expect(prompt.contains("Movement: rising"))
    }
}
