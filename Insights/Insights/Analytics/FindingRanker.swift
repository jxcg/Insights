import Foundation

/// Decides what actually gets said.
///
/// Each detector measures in its own units: standard deviations, percent,
/// correlation. This puts them on one scale and cuts the day to a short list.
enum FindingRanker {
    /// How many findings a day can hold. Below the line is never narrated,
    /// which makes this the sharpest knob in the engine.
    static let maximumFindings = 5

    /// What a warning is worth against merely interesting news.
    /// Small on purpose: settles near-ties, nothing more.
    static let cautionaryWeight = 1.25

    /// Picks the day's short list. Every metric gets one slot before any metric
    /// gets a second, then leftover slots go to the best runners-up.
    ///
    /// Without that rule correlations win every morning. They stay true all
    /// week, so the same one takes the same slot every day.
    static func rank(_ findings: [Finding]) -> [Finding] {
        let ordered = findings.sorted(by: isRankedAbove)

        var selected: [Finding] = []
        var passedOver: [Finding] = []
        var metricsAlreadyHeard: Set<AnalyticMetric> = []

        for finding in ordered {
            guard selected.count < maximumFindings else { break }
            if metricsAlreadyHeard.contains(finding.metric) {
                passedOver.append(finding)
            } else {
                metricsAlreadyHeard.insert(finding.metric)
                selected.append(finding)
            }
        }

        for finding in passedOver where selected.count < maximumFindings {
            selected.append(finding)
        }

        // picking settled which findings make the list. Reader still wants
        // them best first.
        return selected.sorted(by: isRankedAbove)
    }

    /// What a finding is worth: how far past its detector's threshold it
    /// landed, reduced by patchy history, nudged up if it is a warning.
    static func score(_ finding: Finding) -> Double {
        strength(of: finding) * confidenceWeight(of: finding) * toneWeight(of: finding)
    }

    /// How far past its detector's threshold a finding landed.
    ///
    /// At the threshold this is 1, and every doubling past it adds 1. That is
    /// what log2 does. Using the raw number would let one freak reading dwarf
    /// everything else. Capping it would make two extreme findings tie.
    static func strength(of finding: Finding) -> Double {
        // below the threshold log2 goes negative and wrecks the sort order
        let multiplesOfBar = max(finding.magnitude / qualifyingMagnitude(for: finding.type), 1)
        return 1 + log2(multiplesOfBar)
    }

    /// Threshold each detector refuses to report below. Read from the detectors
    /// themselves, so tuning one moves the ranking with it.
    private static func qualifyingMagnitude(for type: Finding.FindingType) -> Double {
        switch type {
        case .anomaly: AnomalyDetector.zScoreThreshold
        case .trend: TrendDetector.relativeChangeThreshold
        case .correlation: CorrelationDetector.correlationThreshold
        }
    }

    /// What patchy history costs. Half the score is earned outright, half is on
    /// offer for evidence, so thin data still competes instead of vanishing.
    private static func confidenceWeight(of finding: Finding) -> Double {
        0.5 + 0.5 * finding.confidence
    }

    private static func toneWeight(of finding: Finding) -> Double {
        finding.tone == .cautionary ? cautionaryWeight : 1
    }

    /// Best first, every tie broken by something fixed. A list that reshuffles
    /// itself each morning reads as untrustworthy.
    private static func isRankedAbove(_ lhs: Finding, _ rhs: Finding) -> Bool {
        let leftScore = score(lhs)
        let rightScore = score(rhs)
        if leftScore != rightScore {
            return leftScore > rightScore
        }
        if lhs.type != rhs.type {
            return stageOrder(of: lhs.type) < stageOrder(of: rhs.type)
        }
        if lhs.metric.displayName != rhs.metric.displayName {
            return lhs.metric.displayName < rhs.metric.displayName
        }
        return (lhs.drivingMetric?.displayName ?? "") < (rhs.drivingMetric?.displayName ?? "")
    }

    /// Who speaks first at equal scores: yesterday's news, then where things
    /// are heading, then a relationship that was true last week too.
    private static func stageOrder(of type: Finding.FindingType) -> Int {
        switch type {
        case .anomaly: 0
        case .trend: 1
        case .correlation: 2
        }
    }
}
