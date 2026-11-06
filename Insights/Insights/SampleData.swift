#if DEBUG
import Foundation
import SwiftData

/// Ninety days of invented history, written straight into the cache so the app
/// can be run, demoed and usability-tested with no phone and no Health
/// authorisation. It writes exactly the records SyncService would have written,
/// so nothing downstream can tell the difference. The cache is the only thing
/// the screens and the engine ever read.
///
/// Deliberately not random: the same numbers every launch, so a screenshot
/// taken today matches one taken next week and two testers see the same app.
enum SampleData {
    // set by the `-sampleData` launch argument in the scheme; the app says so
    // on screen when it is true, so a tester can never mistake sample numbers
    // for their own
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-sampleData")
    }

    /// An in-memory store already full of history. Hand it to a #Preview, or to
    /// the app itself via the `-sampleData` launch argument.
    @MainActor
    static func container(days: Int = 90) -> ModelContainer {
        let container = try! ModelContainer(
            for: DailyMetricRecord.self, SleepNightRecord.self, SyncAnchorRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        populate(container.mainContext, days: days)
        return container
    }

    // one record per metric per day, plus a night's sleep, ending today
    static func populate(_ context: ModelContext, days: Int = 90) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        for daysAgo in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let isRoughPatch = daysAgo < 3

            for kind in MetricKind.allCases {
                context.insert(DailyMetricRecord(
                    date: date,
                    metricKind: kind.rawValue,
                    value: value(for: kind, daysAgo: daysAgo, roughPatch: isRoughPatch),
                    unit: kind.unitLabel))
            }
            context.insert(SleepNightRecord(
                night: night(wakeDay: date, daysAgo: daysAgo, short: isRoughPatch)))
        }

        context.insert(SyncAnchorRecord(typeKey: "sample", anchorData: Data(), lastSynced: .now))
        try? context.save()
    }

    // Absolute units, not one percentage for every metric: a few bpm, wider
    // HRV and activity swings, but only tenths of a degree for temperature.
    // Different phases keep unrelated metrics from moving in lockstep.
    private static func value(for kind: MetricKind, daysAgo: Int, roughPatch: Bool) -> Double {
        let profile: (baseline: Double, variation: Double, shift: Double, phase: Double)
        switch kind {
        case .heartRate: profile = (68, 4, 3, 0.2)
        case .restingHeartRate: profile = (54, 3, 3.5, 1.5)
        case .hrv: profile = (62, 9, -10, 1.0)
        case .steps: profile = (8600, 2150, -1800, 2.7)
        case .activeEnergy: profile = (520, 130, -100, 2.9)
        case .basalEnergy: profile = (1950, 50, 0, 4.1)
        case .vo2Max: profile = (46, 0.8, 0, 0.8)
        case .respiratoryRate: profile = (14.5, 0.7, 0.6, 1.9)
        case .wristTemperature: profile = (35.6, 0.25, 0.15, 3.3)
        }
        // The rough patch builds over three days instead of jumping straight
        // to an extreme reading on every recovery input.
        let severity = roughPatch ? 1 - Double(daysAgo) * 0.15 : 0
        return profile.baseline
            + profile.variation * wobble(daysAgo: daysAgo, phase: profile.phase)
            + profile.shift * severity
    }

    // Two cycles give bounded, repeatable variation without a perfect daily
    // sawtooth or any randomness. The amplitude stays within -1...1.
    private static func wobble(daysAgo: Int, phase: Double) -> Double {
        let day = Double(daysAgo)
        return 0.65 * sin(day * 1.7 + phase) + 0.35 * sin(day * 0.63 + 2 * phase)
    }

    // a night filed under the morning it ended, short during the rough patch
    private static func night(wakeDay: Date, daysAgo: Int, short: Bool) -> SleepNight {
        let severity = short ? 1 - Double(daysAgo) * 0.15 : 0
        let hours = 7.4 + 0.85 * wobble(daysAgo: daysAgo, phase: 3.6) - 0.6 * severity
        let asleep = hours * 3600
        let wakeTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: wakeDay)!
        return SleepNight(
            wakeDay: wakeDay,
            start: wakeTime.addingTimeInterval(-asleep),
            end: wakeTime,
            asleep: asleep,
            deep: asleep * 0.18,
            rem: asleep * 0.22)
    }
}
#endif
