import Foundation

/// The gate every AI draft passes through before a user sees it.
///
/// Rejecting is cheap: a rejected draft just means the engine's own sentence
/// is shown instead. Letting a bad draft through is not: a wrong number, a
/// flipped direction or a cheerful line about a warning sign undermines the
/// whole app. So the rules lean strict, and anything in doubt fails.
///
/// The checks are word-level, so they catch the usual ways a rewording goes
/// wrong, not every possible one. Correlations are never reworded at all: a
/// flipped sign there inverts the only fact the sentence carries, and the
/// wording cannot be checked reliably.
enum NarrationCheck {
    // long enough for one full sentence, short enough to stop rambling
    static let maximumLength = 220

    /// Whether a finding goes to the model at all.
    static func isNarratable(_ finding: Finding) -> Bool {
        finding.type != .correlation
    }

    /// The draft's sentence, tidied, if it passes every rule. nil means use
    /// the template.
    static func accepted(_ draft: NarrationDraft, for finding: Finding) -> String? {
        let sentence = draft.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = sentence.lowercased()
        let wordSet = Set(words(in: lowered))
        guard isNarratable(finding),
              !sentence.isEmpty,
              sentence.count <= maximumLength,
              // the model's echo of the tone it was given. Only proves it
              // followed the instruction; the word rules below check the
              // sentence itself.
              draft.tone == finding.tone,
              isOneSentence(sentence),
              keepsNumbers(sentence, of: finding),
              wordSet.isDisjoint(with: bannedWords),
              !lowered.contains("n't"), !lowered.contains("n’t"),
              !bannedPhrases.contains(where: lowered.contains),
              keepsDirection(wordSet, of: finding),
              namesMetric(lowered, of: finding) else {
            return nil
        }
        return sentence
    }

    /// What the model is asked to do with one finding. The facts are the
    /// engine's `meaning`; direction and tone are stated outright so the model
    /// never has to work them out.
    static func prompt(for finding: Finding) -> String {
        """
        Observation: \(finding.meaning)
        Movement: \(finding.direction.rawValue). Tone: \(finding.tone.rawValue).
        Rewrite the observation as one short, plain sentence spoken to the person \
        it describes. Keep the same meaning and the same tone. Name the metric. \
        Use only numbers that appear in the observation, each with the same unit, \
        written as digits. Set tone to \(finding.tone.rawValue).
        """
    }

    /// Standing instructions for every narration session.
    static let instructions = """
        You reword short observations about a person's own health data into \
        plain, calm English. You never give advice, never suggest causes, never \
        diagnose, never mention doctors, never use negatives, and never add \
        numbers or facts that are not in the observation. Cautionary \
        observations stay sober; positive ones stay modest. Write exactly one \
        sentence with no exclamation marks.
        """

    // MARK: Sentence shape

    // one sentence: a full stop is fine at the end, and inside numbers like
    // 7.5, but not between sentences
    private static func isOneSentence(_ sentence: String) -> Bool {
        if sentence.contains("!") || sentence.contains("?") || sentence.contains("\n") {
            return false
        }
        return !sentence.dropLast().contains(". ")
    }

    // MARK: Numbers

    /// A number and the unit written after it: "62 bpm", "8 %", "21 day".
    struct Quantity: Equatable {
        let number: String
        let unit: String
    }

    // every number in the draft, with its unit, must appear in what the
    // engine said, in the same order, and none of the engine's headline
    // numbers may go missing. Catches invented, rounded and converted
    // figures, two figures swapped ("54, above your usual 62"), and one
    // dropped so the other changes role ("above its usual 62").
    private static func keepsNumbers(_ sentence: String, of finding: Finding) -> Bool {
        let drafted = quantities(in: sentence)
        let headline = quantities(in: finding.plainStatement)
        let inOrder = isInOrder(drafted, within: headline)
            || isInOrder(drafted, within: quantities(in: finding.meaning))
        return inOrder && headline.allSatisfy(drafted.contains)
    }

    // `part` appears within `whole` in the same order, gaps allowed
    private static func isInOrder(_ part: [Quantity], within whole: [Quantity]) -> Bool {
        var remaining = whole[...]
        for quantity in part {
            guard let index = remaining.firstIndex(of: quantity) else { return false }
            remaining = remaining[(index + 1)...]
        }
        return true
    }

    /// Numbers as written, thousands separators removed, each with the word
    /// or "%" straight after it. "8,640 steps" gives 8640 step; "about 8%"
    /// gives 8 %; "21-day" gives 21 day.
    static func quantities(in text: String) -> [Quantity] {
        let characters = Array(text)
        var found: [Quantity] = []
        var index = 0
        while index < characters.count {
            guard isDigit(characters[index]) else {
                index += 1
                continue
            }
            var number = ""
            while index < characters.count {
                let character = characters[index]
                if isDigit(character) {
                    number.append(character)
                } else if character == "." || character == ",",
                          index + 1 < characters.count, isDigit(characters[index + 1]) {
                    // inside a number: keep the decimal point, drop the separator
                    if character == "." { number.append(character) }
                } else {
                    break
                }
                index += 1
            }
            found.append(Quantity(number: number, unit: unit(after: characters, from: &index)))
        }
        return found
    }

    // the unit right after a number, skipping one space or hyphen
    private static func unit(after characters: [Character], from index: inout Int) -> String {
        if index < characters.count, characters[index] == "%" {
            index += 1
            return "%"
        }
        var cursor = index
        if cursor < characters.count, characters[cursor] == " " || characters[cursor] == "-" {
            cursor += 1
        }
        var word = ""
        while cursor < characters.count,
              characters[cursor].isLetter || characters[cursor] == "/" || characters[cursor] == "°"
                || characters[cursor] == "·" {
            word.append(characters[cursor])
            cursor += 1
        }
        word = word.lowercased()
        // "days" and "day", "steps" and "step" mean the same unit
        if word.count > 3, word.hasSuffix("s") {
            word.removeLast()
        }
        return word
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    // MARK: Words

    // advice, cheer, alarm, causes, hedges, negatives, and numbers in words
    private static let bannedWords: Set<String> = [
        // advice
        "should", "must", "need", "needs", "try", "consider", "recommend", "recommended",
        "advise", "advice", "suggest", "suggests", "keep", "take", "rest", "relax", "easy",
        "hydrate", "drink", "doctor", "physician", "gp",
        // diagnosis, causes, hedges
        "diagnose", "diagnosis", "illness", "disease", "sick", "ill", "infection",
        "stress", "stressed", "because", "due", "cause", "caused", "causing", "sign", "signs",
        "indicates", "indicate", "likely", "probably", "possibly", "may", "might", "could",
        // cheer and alarm
        "great", "good", "nice", "excellent", "fantastic", "amazing", "awesome", "wonderful",
        "congratulations", "worry", "worrying", "worryingly", "worried", "alarming",
        "concerning", "dangerous", "unfortunately", "sadly",
        // negatives, which can flip a fact without changing a number
        "not", "no", "never", "neither", "nor", "without",
        // numbers in words, which slip past the number check
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "dozen", "hundred", "thousand", "twice", "double", "doubled", "triple", "half", "halved",
    ]

    private static let bannedPhrases = ["well done", "keep it up", "good news", "might want"]

    private static let risingWords: Set<String> = [
        "rose", "risen", "rising", "rise", "rises", "higher", "up", "increased", "increase",
        "increasing", "climbed", "climbing", "climb", "jumped", "jump", "spiked", "spike",
        "elevated", "above", "more", "longer", "extra",
    ]
    private static let fallingWords: Set<String> = [
        "fell", "fallen", "falling", "fall", "falls", "lower", "down", "dropped", "drop",
        "drops", "dipped", "dip", "dips", "decreased", "decrease", "decreasing", "declined",
        "declining", "reduced", "slipped", "below", "less", "fewer", "shorter",
    ]

    // a rising finding must not be described with falling words, or the
    // reverse
    private static func keepsDirection(_ wordSet: Set<String>, of finding: Finding) -> Bool {
        switch finding.direction {
        case .rising: return wordSet.isDisjoint(with: fallingWords)
        case .falling: return wordSet.isDisjoint(with: risingWords)
        case .steady: return wordSet.isDisjoint(with: risingWords.union(fallingWords))
        }
    }

    // the draft must say which metric it is about, and not a neighbouring one
    private static func namesMetric(_ lowered: String, of finding: Finding) -> Bool {
        switch finding.metric {
        case .quantity(let kind):
            switch kind {
            case .heartRate:
                return lowered.contains("heart rate") && !lowered.contains("resting")
            case .restingHeartRate:
                return lowered.contains("resting heart rate")
            case .hrv:
                return lowered.contains("hrv") || lowered.contains("heart rate variability")
            case .steps:
                return lowered.contains("step")
            case .activeEnergy:
                return lowered.contains("active energy")
            case .basalEnergy:
                return lowered.contains("resting energy")
            case .vo2Max:
                return lowered.contains("vo₂") || lowered.contains("vo2")
            case .respiratoryRate:
                return lowered.contains("respiratory rate") || lowered.contains("breathing rate")
            case .wristTemperature:
                return lowered.contains("temperature")
            }
        case .sleepDuration:
            return (lowered.contains("sleep") || lowered.contains("slept"))
                && !lowered.contains("deep") && !lowered.contains("rem ")
        case .deepSleepDuration:
            return lowered.contains("deep sleep")
        case .remSleepDuration:
            return lowered.contains("rem sleep")
        }
    }

    // runs of letters; apostrophes kept so "it's" stays one word
    static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0 == "'" || $0 == "’") }.map(String.init)
    }
}
