import Foundation

/// Raw sleep samples in, one clean summary per night out. That is the shape
/// the cache stores and the engine judges.
///
/// Pure logic, no Apple Health, so it is easy to test.
enum SleepNightAggregator {

    /// One unbroken stretch of sleep: a night, or a nap.
    struct Session {
        var samples: [SleepSample]
        var start: Date
        var end: Date

        var duration: TimeInterval {
            end.timeIntervalSince(start)
        }
    }

    /// Two hours, the line between one sleep and the next. Awake for less and
    /// it is the same sleep, so a rough night stays in one piece. Awake for
    /// longer and what follows is its own thing, like a nap.
    static let sessionGap: TimeInterval = 7200

    /// Glues samples into sessions, in time order. A sample close to the
    /// current sleep joins it, a long gap starts a new one. Overlapping watch
    /// and phone samples land in the same session.
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

    /// A sleep belongs to the day you wake from it, so 23:30 to 07:00 files
    /// under the morning. Health app does the same. Longest sleep of a day is
    /// the night, shorter ones are naps and get dropped.
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

    /// Whole pipeline in one call: samples in, nights out, oldest first.
    /// Cluster into sessions, pick each day's night, add up durations.
    static func nights(from samples: [SleepSample], calendar: Calendar = .current) -> [SleepNight] {
        nightsByWakeDay(sessions(from: samples), calendar: calendar)
            .map { wakeDay, session in night(for: session, wakeDay: wakeDay) }
            .sorted { $0.wakeDay < $1.wakeDay }
    }

    /// Sums one session into a night without double counting. Phone and watch
    /// can log the same minutes, so overlaps merge before adding and every
    /// minute counts once. Deep and REM stay nil with no stage data at all.
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

    /// Total time the samples cover, counting overlap once. Lay them on a
    /// timeline, fuse the ones that touch, add up the blocks.
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
