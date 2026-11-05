import Foundation

/// Last step of the pipeline: a ranked Finding in, a sentence the user reads
/// out.
///
///     … → Finding → InsightGenerator → DailyDigest → screen
///
/// The on-device model only rewords. Every draft it writes is checked by
/// `NarrationCheck` against the Finding it came from, and anything that fails
/// the check, throws, or never arrives is replaced by the engine's own
/// `plainStatement`. So the screen always has a sentence, and a broken or
/// missing model looks exactly like a working one.
///
/// Nothing in this file touches Foundation Models. `SystemNarrator` is the
/// only file that does.
final class InsightGenerator {
    private let narrator: (any Narrator)?
    private let requestTimeout: Duration

    /// nil narrator means "AI unavailable": every sentence is the template.
    init(narrator: (any Narrator)?, requestTimeout: Duration = .seconds(10)) {
        self.narrator = narrator
        self.requestTimeout = requestTimeout
    }

    /// The generator the app runs with: Apple's on-device model when this
    /// device has it ready, templates otherwise.
    static func live() -> InsightGenerator {
        InsightGenerator(narrator: SystemNarrator.makeIfAvailable())
    }

    /// Instant, never fails. Screens show this first and swap in the narrated
    /// version once it is ready.
    static func templateDigest(for findings: [Finding]) -> DailyDigest {
        DailyDigest(insights: findings.map(NarratedInsight.template))
    }

    /// One sentence per finding, in the order given. Requests are awaited one
    /// at a time. A timeout cancels the request without waiting for the model
    /// to stop, so a stuck request cannot hold up the rest of the digest.
    func narrate(_ findings: [Finding]) async -> DailyDigest {
        guard let narrator else {
            return Self.templateDigest(for: findings)
        }

        var insights: [NarratedInsight] = []
        for finding in findings {
            // a cancelled screen gets templates for whatever is left, and
            // correlations always keep the engine's wording
            if Task.isCancelled || !NarrationCheck.isNarratable(finding) {
                insights.append(.template(finding))
                continue
            }
            let draft = await draft(for: finding, using: narrator)
            if let draft, let sentence = NarrationCheck.accepted(draft, for: finding) {
                insights.append(NarratedInsight(finding: finding, sentence: sentence, source: .model))
            } else {
                insights.append(.template(finding))
            }
        }
        return DailyDigest(insights: insights)
    }

    private func draft(for finding: Finding, using narrator: any Narrator) async -> NarrationDraft? {
        let (stream, continuation) = AsyncStream<NarrationDraft>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Unstructured deliberately: a task group would wait for a model that
        // ignores cancellation even after its timeout child has finished.
        let request = Task {
            defer { continuation.finish() }
            guard !Task.isCancelled else { return }
            if let draft = try? await narrator.draft(for: finding) {
                continuation.yield(draft)
            }
        }
        let timeout = requestTimeout
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            continuation.finish()
        }
        defer {
            request.cancel()
            timer.cancel()
            continuation.finish()
        }
        // Cancellation ends the iteration too. Finishing the stream ignores
        // late model results; neither timeout nor cancellation awaits them.
        for await draft in stream { return Task.isCancelled ? nil : draft }
        return nil
    }
}

/// Anything that can draft a sentence for a Finding. The real one is Apple's
/// on-device model; tests use a stand-in that returns whatever they need.
protocol Narrator {
    func draft(for finding: Finding) async throws -> NarrationDraft
}

/// What a narrator hands back, before checking. `tone` is the model's own
/// reading of the tone it was told to keep, so a draft that drifted can be
/// caught.
struct NarrationDraft {
    let sentence: String
    let tone: Finding.Tone
}

/// The day's findings as the user reads them, best first.
struct DailyDigest {
    let insights: [NarratedInsight]
}

/// One finding and the sentence that represents it.
struct NarratedInsight {
    enum Source {
        case model
        case template
    }

    let finding: Finding
    let sentence: String

    // for debugging only; the screen treats both the same
    let source: Source

    static func template(_ finding: Finding) -> NarratedInsight {
        NarratedInsight(finding: finding, sentence: finding.plainStatement, source: .template)
    }
}
