import Foundation
import FoundationModels

// The only file in the app that imports Foundation Models. Everything the
// model is told, and every check on what it says back, lives in
// NarrationCheck, so it can be read and tested without the model.

/// Apple's on-device language model, used as a Narrator.
///
/// A fresh session per finding: sessions remember earlier turns, and one
/// finding's wording must never leak into the next.
struct SystemNarrator: Narrator {
    /// nil when this device cannot run the model right now: not eligible,
    /// Apple Intelligence off, or the model still downloading.
    static func makeIfAvailable() -> SystemNarrator? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }
        return SystemNarrator()
    }

    func draft(for finding: Finding) async throws -> NarrationDraft {
        let session = LanguageModelSession(instructions: NarrationCheck.instructions)
        // greedy: the same finding gets the same wording every time the app
        // opens, and passes or fails the check the same way
        let response = try await session.respond(
            to: NarrationCheck.prompt(for: finding),
            generating: InsightCard.self,
            options: GenerationOptions(sampling: .greedy))
        return NarrationDraft(
            sentence: response.content.sentence,
            tone: Self.findingTone(response.content.tone))
    }

    // kept out of the generated types, which stay free of app isolation
    private static func findingTone(_ tone: InsightTone) -> Finding.Tone {
        switch tone {
        case .positive: .positive
        case .neutral: .neutral
        case .cautionary: .cautionary
        }
    }
}

/// What the model is asked to fill in. Guided generation means it can only
/// answer in this shape, so the tone always comes back as one of three values
/// and can be compared with the engine's.
@Generable
nonisolated struct InsightCard {
    @Guide(description: "One plain sentence restating the observation, with no advice.")
    var sentence: String

    @Guide(description: "The tone given in the prompt, unchanged.")
    var tone: InsightTone
}

@Generable
nonisolated enum InsightTone {
    case positive
    case neutral
    case cautionary
}
