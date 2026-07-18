import Foundation

/// Turns raw sleep samples into nightly summaries
/// pure logic with no HealthKit so it's easy to test
/// the analytics engine will later read what this produces
enum SleepNightAggregator {

    /// One sleep episode, a night or a nap
    struct Session {
        var samples: [SleepSample]
        var start: Date
        var end: Date

        var duration: TimeInterval {
            end.timeIntervalSince(start)
        }
    }

    /// 7200s = 2 hours, the cutoff between separate sleeps
    /// awake under 2h and it's still the same sleep, a rough night stays whole
    /// awake longer and the next sleep is its own thing, like an afternoon nap
    /// this cutoff is how the app tells nights and naps apart
    static let sessionGap: TimeInterval = 7200

    /// Glues time-ordered samples into sessions
    /// a sample near the current sleep joins it, a big gap starts a new one
    /// overlapping samples from two sources end up in the same session
    static func sessions(from samples: [SleepSample]) -> [Session] {
        var sessions: [Session] = []
        var current: Session?

        for sample in samples {
            if var session = current, sample.start.timeIntervalSince(session.end) <= sessionGap {
                session.samples.append(sample)
                session.end = max(session.end, sample.end)
                current = session
            } else {
                if let finished = current {
                    sessions.append(finished)
                }
                current = Session(samples: [sample], start: sample.start, end: sample.end)
            }
        }
        if let finished = current {
            sessions.append(finished)
        }
        return sessions
    }

    /// A sleep belongs to the day you WAKE UP from it
    /// so 23:30 to 07:00 counts as the morning's date, same as the Health app
    /// longest sleep of the day is the night, shorter ones are naps and dropped
    static func nightsByWakeDay(_ sessions: [Session], calendar: Calendar = .current) -> [Date: Session] {
        var nights: [Date: Session] = [:]
        for session in sessions {
            let wakeDay = calendar.startOfDay(for: session.end)
            if let currentNight = nights[wakeDay], currentNight.duration >= session.duration {
                continue
            }
            nights[wakeDay] = session
        }
        return nights
    }

    /// The whole pipeline in one call, samples in, nights out oldest first
    /// cluster into sessions, pick each day's night, sum the merged durations
    static func nights(from samples: [SleepSample], calendar: Calendar = .current) -> [SleepNight] {
        nightsByWakeDay(sessions(from: samples), calendar: calendar)
            .map { wakeDay, session in night(for: session, wakeDay: wakeDay) }
            .sorted { $0.wakeDay < $1.wakeDay }
    }

    /// Sums one session into its night summary without double counting
    /// phone and watch can log the same minutes so overlaps are merged
    /// before adding, every minute counts ONCE
    /// deep and rem stay nil if no sample in the session has stages
    static func night(for session: Session, wakeDay: Date) -> SleepNight {
        let hasStageData = session.samples.contains { $0.stage != .unspecified }
        return SleepNight(
            wakeDay: wakeDay,
            start: session.start,
            end: session.end,
            asleep: mergedDuration(of: session.samples),
            deep: hasStageData ? mergedDuration(of: session.samples.filter { $0.stage == .deep }) : nil,
            rem: hasStageData ? mergedDuration(of: session.samples.filter { $0.stage == .rem }) : nil
        )
    }

    /// Total time covered by the samples, counting overlaps once
    /// lays intervals on a timeline, fuses the ones that touch,
    /// then adds up the fused blocks
    static func mergedDuration(of samples: [SleepSample]) -> TimeInterval {
        let sorted = samples.sorted { $0.start < $1.start }

        var total: TimeInterval = 0
        var blockStart: Date?
        var blockEnd: Date?

        for sample in sorted {
            if let end = blockEnd, sample.start <= end {
                blockEnd = max(end, sample.end)
            } else {
                if let start = blockStart, let end = blockEnd {
                    total += end.timeIntervalSince(start)
                }
                blockStart = sample.start
                blockEnd = sample.end
            }
        }
        if let start = blockStart, let end = blockEnd {
            total += end.timeIntervalSince(start)
        }
        return total
    }
}
