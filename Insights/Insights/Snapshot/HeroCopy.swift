import Foundation

/// The words on the readiness card: a headline, and one sentence saying what
/// the score is made of.
///
/// Facts only, no advice: the card says how this morning compares with the
/// user's own normal, never what to do about it. Low recovery reads softer,
/// not louder.
enum HeroCopy {
    struct Copy: Equatable {
        let headline: String
        let explanation: String
    }

    // scores at or above this read as better than usual: one standard
    // deviation above normal, mirroring the low-recovery line below it
    static let betterThanUsualFrom = Int(ReadinessCalculator.typicalScore + ReadinessCalculator.pointsPerStandardDeviation)

    static func copy(for readiness: Readiness?) -> Copy {
        guard let readiness else {
            return Copy(
                headline: "Building your baseline",
                explanation: "A readiness score needs about a week of HRV, resting heart rate or sleep. "
                    + "Findings appear as your history grows.")
        }

        let names = readiness.inputsUsed.map(inputName)
        let inputs = listed(names)
        let several = names.count > 1
        // "Taken together, your HRV and sleep are…" but "Your HRV is…".
        // "Favourable", never "above" or "below": a higher resting heart rate
        // is the unfavourable direction, so up and down would mislead.
        let subject = several ? "Taken together, your \(inputs)" : "Your \(inputs)"
        let isAre = several ? "are" : "is"

        switch readiness.state {
        case .lowRecovery:
            return Copy(
                headline: "Recovery is running low",
                explanation: "\(subject) \(isAre) less favourable than your usual for the last 30 days.")
        case .recovered where readiness.score >= betterThanUsualFrom:
            return Copy(
                headline: "Well recovered",
                explanation: "\(subject) \(isAre) more favourable than your usual for the last 30 days.")
        case .recovered:
            return Copy(
                headline: "Recovered",
                explanation: "\(subject) \(isAre) in line with your last 30 days.")
        }
    }

    /// "+4 since yesterday", "−3 since yesterday", "Same as yesterday"
    static func delta(_ delta: Int?) -> String? {
        guard let delta else { return nil }
        if delta == 0 { return "Same as yesterday" }
        return delta > 0 ? "+\(delta) since yesterday" : "−\(abs(delta)) since yesterday"
    }

    private static func inputName(_ metric: AnalyticMetric) -> String {
        switch metric {
        case .quantity(.hrv): "HRV"
        case .quantity(.restingHeartRate): "resting heart rate"
        case .sleepDuration: "sleep"
        default: metric.displayName.lowercased()
        }
    }

    // "a", "a and b", "a, b and c"
    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
