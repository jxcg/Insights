import Foundation

/// Everything the Summary screen shows, worked out in one place.
///
///     cache → engine + readiness → narration → DailySnapshot → Summary
///
/// The screen only lays this out. It makes no judgement of its own, so every
/// rule about what to show sits here, where it can be tested without a view.
struct DailySnapshot {
    /// nil when there is too little history to score this morning
    let readiness: Readiness?

    /// thin data reads as recovered: no evidence of a bad morning is not
    /// evidence of one
    var recoveryState: RecoveryState { readiness?.state ?? .recovered }

    let tiles: [MetricTile]

    /// the only part narration changes, so it alone is replaced when the
    /// reworded sentences arrive
    var insights: [Insight]

    /// seven mornings, oldest first, ending today
    let weekReadiness: [DayReadiness]

    let lastSynced: Date?
    let syncFresh: Bool

    /// the freshest numbers are not final yet; see `ProvisionalData`
    let provisional: ProvisionalData

    /// false when the cache holds nothing at all: before the first sync, or
    /// when Health access was refused
    let hasAnyData: Bool
}

/// One row in the insights stack.
struct Insight {
    let sentence: String

    /// the numbers behind the sentence, in a quieter line underneath
    let evidence: String

    /// SF Symbol name
    let symbol: String

    let tone: Finding.Tone
}

/// One square in the metric grid.
struct MetricTile {
    enum Metric: CaseIterable {
        case sleep
        case hrv
        case restingHeartRate
        case steps
    }

    /// The small drawing under the number. Each metric has its own.
    enum Visual {
        /// last night's split, as shares of time asleep (0 to 1)
        case sleepStages(deep: Double, rem: Double, core: Double)
        /// recent days, oldest first
        case sparkline([Double])
        /// yesterday against the goal, 0 to 1 (can pass 1)
        case progress(Double)
        /// nothing to draw yet
        case empty
    }

    let metric: Metric

    /// "7.2", "54", "8,640"; nil when there is no recent reading
    let value: String?
    let unit: String

    /// a quiet comparison, such as "usually 7.4 h"
    let caption: String?

    let visual: Visual

    /// true only when the latest reading is out of its normal range in the
    /// unwelcome direction. It gets the amber treatment, and nothing else does.
    let needsAttention: Bool
}

/// Data that exists but is not final yet. It is shown, marked as such, rather
/// than hidden or treated as the real figure.
struct ProvisionalData {
    /// woke within the last two hours, so more sleep could still join the
    /// night; until then it stays out of every baseline and score
    let lastNightStillSettling: Bool

    /// asleep so far on that unsettled night, in hours, to show it live
    let lastNightHoursSoFar: Double?

    static let settled = ProvisionalData(lastNightStillSettling: false, lastNightHoursSoFar: nil)
}
