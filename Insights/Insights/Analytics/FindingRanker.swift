import Foundation

/// Fifth stage on the path set out in InsightsApp, and the one that decides
/// what actually gets said. Each detector measures in its own units; this puts
/// them on one scale and cuts the day down to the list narration ever sees.
enum FindingRanker {
    /// How many findings a day's list may hold. Whatever falls below the line
    /// is never narrated, which makes this the sharpest knob in the engine.
    static let maximumFindings = 5

    /// What a warning is worth against merely interesting news. Small on
    /// purpose: it settles near-ties and nothing more.
    static let cautionaryWeight = 1.25

    /// The day's short list: every metric gets a hearing before any metric gets
    /// a second slot, then leftover slots go to the strongest passed over.
    /// Without that split, correlations — true all week — would hold the same
    /// slot every morning.
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

        // selection settled which findings make the list; the reader still
        // wants them best first
        return selected.sorted(by: isRankedAbove)
    }

    /// What a finding is worth: how far past its stage's bar it landed, held
    /// back by thin history and nudged up if it is a warning.
    static func score(_ finding: Finding) -> Double {
        strength(of: finding) * confidenceWeight(of: finding) * toneWeight(of: finding)
    }

    /// How far past its own stage's bar a finding landed, compressed rather than
    /// capped: at the bar is 1, and every doubling past it adds 1. A freak
    /// reading still leads without flattening everything under it, and two
    /// extreme findings stay distinguishable.
    static func strength(of finding: Finding) -> Double {
        // a magnitude under the bar would take log2 negative and poison the sort
        let multiplesOfBar = max(finding.magnitude / qualifyingMagnitude(for: finding.type), 1)
        return 1 + log2(multiplesOfBar)
    }

    /// The magnitude each stage refuses to speak below. Read from the detectors
    /// so tuning a threshold moves the ranking with it.
    private static func qualifyingMagnitude(for type: Finding.FindingType) -> Double {
        switch type {
        case .anomaly: AnomalyDetector.zScoreThreshold
        case .trend: TrendDetector.relativeChangeThreshold
        case .correlation: CorrelationDetector.correlationThreshold
        }
    }

    /// How much patchy history costs a finding. Half the score is earned
    /// outright and half is on offer for evidence, so thin data still competes
    /// rather than disappearing.
    private static func confidenceWeight(of finding: Finding) -> Double {
        0.5 + 0.5 * finding.confidence
    }

    private static func toneWeight(of finding: Finding) -> Double {
        finding.tone == .cautionary ? cautionaryWeight : 1
    }

    /// Best first, with every tie broken by something fixed. A list read each
    /// morning that reshuffles itself reads as untrustworthy.
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

    /// Which stage speaks first when scores are level: yesterday's news, then
    /// where things are heading, then a relationship that held last week too.
    private static func stageOrder(of type: Finding.FindingType) -> Int {
        switch type {
        case .anomaly: 0
        case .trend: 1
        case .correlation: 2
        }
    }
}
