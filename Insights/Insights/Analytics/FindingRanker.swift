import Foundation

/// Fifth stage on the path set out in InsightsApp, and the one that decides
/// what actually gets said. Each detector answers its own question in its own
/// units; this file puts every finding on a single scale, orders them, and cuts
/// the day down to the short list the narration layer is ever shown.
enum FindingRanker {
    /// How many findings a day's list may hold. Whatever falls below the line
    /// is never narrated, which makes this the sharpest knob in the engine.
    static let maximumFindings = 5

    /// What a warning is worth against news that is merely interesting. Small
    /// on purpose: it settles near-ties and nothing more, so a faint worry can
    /// never outrank something the user plainly needs to know.
    static let cautionaryWeight = 1.25

    /// The day's short list. The first pass gives every metric a hearing before
    /// any metric gets a second slot; the second fills whatever is left over
    /// with the strongest of the findings that were passed over.
    ///
    /// The split matters because the stages age differently. An anomaly or a
    /// trend is news and changes daily, while a correlation is a standing fact
    /// about the last 90 days — ranked on score alone it would hold the same
    /// slot every morning, saying the same thing.
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

    /// How far past its own stage's bar a finding landed. Each stage measures in
    /// its own units — standard deviations, percentage change, r — so dividing by
    /// the bar is what makes them comparable at all.
    ///
    /// The result is compressed rather than capped: exactly at the bar is 1, and
    /// every doubling past it adds 1, so four times the bar is worth 3 and
    /// sixteen times only 5. A freak reading still leads the list without
    /// flattening everything under it, and two extreme findings stay
    /// distinguishable instead of collapsing onto the same number.
    static func strength(of finding: Finding) -> Double {
        // detectors never emit below their own bar, but a magnitude that slipped
        // under would take log2 negative or undefined and poison the sort
        let multiplesOfBar = max(finding.magnitude / qualifyingMagnitude(for: finding.type), 1)
        return 1 + log2(multiplesOfBar)
    }

    /// The magnitude each stage refuses to speak below. Read from the detectors
    /// rather than restated here, so tuning a threshold moves the ranking with
    /// it instead of quietly disagreeing.
    private static func qualifyingMagnitude(for type: Finding.FindingType) -> Double {
        switch type {
        case .anomaly: AnomalyDetector.zScoreThreshold
        case .trend: TrendDetector.relativeChangeThreshold
        case .correlation: CorrelationDetector.correlationThreshold
        }
    }

    /// How much patchy history costs a finding. Half the score is earned
    /// outright and half is on offer for evidence, so a finding drawn from thin
    /// data still competes rather than disappearing — the same rule the
    /// detectors follow when they scale confidence instead of refusing.
    private static func confidenceWeight(of finding: Finding) -> Double {
        0.5 + 0.5 * finding.confidence
    }

    private static func toneWeight(of finding: Finding) -> Double {
        finding.tone == .cautionary ? cautionaryWeight : 1
    }

    /// Best first, with every tie broken by something fixed. Two findings that
    /// score identically must not swap places between runs: this list is read
    /// each morning, and one that reshuffles itself reads as untrustworthy.
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

    /// Which stage speaks first when scores are level: what happened yesterday
    /// before where things are heading, and both before a standing relationship
    /// that was just as true last week.
    private static func stageOrder(of type: Finding.FindingType) -> Int {
        switch type {
        case .anomaly: 0
        case .trend: 1
        case .correlation: 2
        }
    }
}
