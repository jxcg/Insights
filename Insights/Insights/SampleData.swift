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
    /// Whether this run is on invented data. Set by the `-sampleData` launch
    /// argument in the scheme; the app says so on screen when it is true, so a
    /// tester can never mistake sample numbers for their own.
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

    /// One record per metric per day, plus a night's sleep, ending today.
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

    /// Roughly plausible resting levels for a reasonably fit adult.
    private static let baselines: [MetricKind: Double] = [
        .heartRate: 68,
        .restingHeartRate: 54,
        .hrv: 62,
        .steps: 8600,
        .activeEnergy: 520,
        .basalEnergy: 1650,
        .vo2Max: 46,
        .respiratoryRate: 14.5,
        .wristTemperature: 35.6,
    ]

    /// A baseline nudged by a repeatable day-to-day wobble, then pushed off it
    /// for the last three days. Without that push the detectors find nothing
    /// and every screen shows an empty state.
    private static func value(for kind: MetricKind, daysAgo: Int, roughPatch: Bool) -> Double {
        let baseline = baselines[kind] ?? 1
        let wobble = sin(Double(daysAgo) * 1.7) * 0.04

        var roughPatchShift = 0.0
        if roughPatch {
            switch kind {
            case .heartRate, .restingHeartRate, .respiratoryRate: roughPatchShift = 0.12
            case .hrv, .steps, .activeEnergy: roughPatchShift = -0.25
            default: break
            }
        }
        return baseline * (1 + wobble + roughPatchShift)
    }

    /// A night filed under the morning it ended, short during the rough patch.
    private static func night(wakeDay: Date, daysAgo: Int, short: Bool) -> SleepNight {
        let hours = (short ? 5.6 : 7.4) + sin(Double(daysAgo) * 1.1) * 0.4
        let asleep = hours * 3600
        let bedtime = wakeDay.addingTimeInterval(-8 * 3600)
        return SleepNight(
            wakeDay: wakeDay,
            start: bedtime,
            end: bedtime.addingTimeInterval(asleep),
            asleep: asleep,
            deep: asleep * 0.18,
            rem: asleep * 0.22)
    }
}
#endif
