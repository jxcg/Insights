import Foundation
import Testing
@testable import Insights

/// How long one Summary refresh takes on a full 90-day cache, the most the
/// app ever keeps.
///
/// Apple's budget for main-thread work after a user action is 100 ms
/// ("Improving app responsiveness"). The time is printed on every run so it
/// can be watched; the hard limit is set well above it, at 500 ms, so a slow
/// shared CI machine cannot fail it by chance while a real regression still
/// does.
@Suite struct PerformanceTests {
    // midday 18 Jul 2026, last night settled
    private let now = day(2026, 7, 18).addingTimeInterval(12 * 3600)

    // 90 days of every metric and a night's sleep each morning, shaped like
    // the app's sample data
    private func ninetyDays() -> (metrics: [DailyMetricRecord], nights: [SleepNightRecord]) {
        var metrics: [DailyMetricRecord] = []
        var nights: [SleepNightRecord] = []
        for daysAgo in 0..<90 {
            let date = utcCalendar.date(byAdding: .day, value: -daysAgo, to: day(2026, 7, 18))!
            let wobble = sin(Double(daysAgo) * 1.7) * 0.04
            for kind in MetricKind.allCases {
                metrics.append(DailyMetricRecord(
                    date: date, metricKind: kind.rawValue, value: 50 * (1 + wobble), unit: kind.unitLabel))
            }
            let asleep = (7.4 + sin(Double(daysAgo) * 1.1) * 0.4) * 3600
            let bedtime = date.addingTimeInterval(-3600)
            nights.append(SleepNightRecord(night: SleepNight(
                wakeDay: date, start: bedtime, end: bedtime.addingTimeInterval(asleep),
                asleep: asleep, deep: asleep * 0.18, rem: asleep * 0.22)))
        }
        return (metrics, nights)
    }

    @Test func aNinetyDayRefreshFitsTheMainThreadBudget() {
        let cache = ninetyDays()
        let clock = ContinuousClock()

        var snapshot: DailySnapshot?
        let refresh = clock.measure {
            // exactly what SummaryView.refresh does before narration
            let history = HealthHistory(metrics: cache.metrics, nights: cache.nights)
            let findings = InsightEngine.dailyFindings(history: history, asOf: now, calendar: utcCalendar)
            snapshot = SnapshotBuilder.build(
                history: history, digest: InsightGenerator.templateDigest(for: findings),
                lastSynced: now, asOf: now, calendar: utcCalendar)
        }

        // what the refresh used to spend just reading records: 14 passes per
        // snapshot (3 detectors, tiles twice, readiness twice, the week 7
        // times), and the snapshot was built twice
        let oldRecordReads = clock.measure {
            for _ in 0..<28 {
                _ = BaselineBuilder.dailySeries(metrics: cache.metrics, nights: cache.nights, asOf: now)
            }
        }
        // "CI:" lines are picked out of the result bundle into the CI log
        print("CI: 90-day Summary refresh \(refresh); the old refresh's 28 record reads alone \(oldRecordReads)")

        #expect(snapshot?.readiness != nil)
        #expect(snapshot?.weekReadiness.count == 7)
        #expect(snapshot?.tiles.count == 4)
        #expect(refresh < .milliseconds(500))
    }

    @Test func historySeriesMatchAStraightforwardReadingOfTheRecords() {
        // the last night ends 30 min before "now", so it is still settling
        // and must stay out, as it always has
        var cache = ninetyDays()
        let settling = now.addingTimeInterval(-1800)
        cache.nights.append(SleepNightRecord(night: SleepNight(
            wakeDay: day(2026, 7, 19), start: settling.addingTimeInterval(-3600), end: settling,
            asleep: 3600, deep: nil, rem: nil)))

        // the old rule, written out plainly
        var expected: [AnalyticMetric: [DatedValue]] = [:]
        for record in cache.metrics {
            guard let kind = MetricKind(rawValue: record.metricKind) else { continue }
            expected[.quantity(kind), default: []].append(DatedValue(day: record.date, value: record.value))
        }
        for night in cache.nights where now.timeIntervalSince(night.end) >= SleepNightAggregator.sessionGap {
            expected[.sleepDuration, default: []].append(DatedValue(day: night.wakeDay, value: night.asleep / 3600))
            if let deep = night.deep {
                expected[.deepSleepDuration, default: []].append(DatedValue(day: night.wakeDay, value: deep / 3600))
            }
            if let rem = night.rem {
                expected[.remSleepDuration, default: []].append(DatedValue(day: night.wakeDay, value: rem / 3600))
            }
        }

        let actual = HealthHistory(metrics: cache.metrics, nights: cache.nights).series(asOf: now)

        #expect(Set(actual.keys) == Set(expected.keys))
        for (metric, series) in expected {
            let sorted = series.sorted { $0.day < $1.day }
            #expect(actual[metric]?.map(\.day) == sorted.map(\.day))
            #expect(actual[metric]?.map(\.value) == sorted.map(\.value))
        }
    }
}
