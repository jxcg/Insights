import Foundation
import Testing
@testable import Insights

/// Fixed calendar so window boundaries never depend on the machine's locale
/// or timezone.
private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    utcCalendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func closeEnough(_ actual: Double?, _ expected: Double) -> Bool {
    guard let actual else { return false }
    return abs(actual - expected) < 0.000001
}

/// The rolling mean and SD maths, checked against values computed by hand.
@Suite struct BaselineMathTests {

    @Test func fiveDayMeanAndSpread() {
        // 50, 52, 54, 56, 58 gives mean 54. Squared deviations 16+4+0+4+16 = 40,
        // sample variance 40/4 = 10, SD is the square root of 10.
        let series = [50.0, 52, 54, 56, 58].enumerated().map { offset, value in
            DatedValue(day: day(2026, 6, 1 + offset), value: value)
        }
        let baseline = MetricBaseline.compute(
            over: series, windowDays: 30, endingOn: day(2026, 6, 5), calendar: utcCalendar)

        #expect(closeEnough(baseline?.mean, 54))
        #expect(closeEnough(baseline?.standardDeviation, 3.162277660168379))
        #expect(baseline?.sampleCount == 5)
        #expect(closeEnough(baseline?.coverage, 5.0 / 30.0))
    }

    @Test func singleDayHasMeanButNoSpread() {
        let series = [DatedValue(day: day(2026, 6, 5), value: 62)]
        let baseline = MetricBaseline.compute(
            over: series, windowDays: 30, endingOn: day(2026, 6, 5), calendar: utcCalendar)

        #expect(closeEnough(baseline?.mean, 62))
        #expect(baseline?.standardDeviation == nil)
        #expect(baseline?.sampleCount == 1)
    }

    @Test func emptyWindowGivesNil() {
        let baseline = MetricBaseline.compute(
            over: [], windowDays: 30, endingOn: day(2026, 6, 5), calendar: utcCalendar)
        #expect(baseline == nil)
    }

    @Test func windowExcludesOlderDays() {
        // a 30-day window ending 1 Jul spans 2 Jun to 1 Jul, so 1 Jun must not
        // count. The remaining 10 and 20 give mean 15, deviations of 5 either
        // way, variance 50/1, SD the square root of 50.
        let series = [
            DatedValue(day: day(2026, 6, 1), value: 100),
            DatedValue(day: day(2026, 6, 2), value: 10),
            DatedValue(day: day(2026, 7, 1), value: 20),
        ]
        let baseline = MetricBaseline.compute(
            over: series, windowDays: 30, endingOn: day(2026, 7, 1), calendar: utcCalendar)

        #expect(baseline?.sampleCount == 2)
        #expect(closeEnough(baseline?.mean, 15))
        #expect(closeEnough(baseline?.standardDeviation, 7.0710678118654755))
    }

    @Test func longerWindowReachesFurtherBack() {
        // a value 40 days old is outside a 30-day window but inside a 60-day one
        let series = [
            DatedValue(day: day(2026, 5, 22), value: 40),
            DatedValue(day: day(2026, 7, 1), value: 60),
        ]
        let thirtyDay = MetricBaseline.compute(
            over: series, windowDays: 30, endingOn: day(2026, 7, 1), calendar: utcCalendar)
        let sixtyDay = MetricBaseline.compute(
            over: series, windowDays: 60, endingOn: day(2026, 7, 1), calendar: utcCalendar)

        #expect(thirtyDay?.sampleCount == 1)
        #expect(closeEnough(thirtyDay?.mean, 60))
        #expect(sixtyDay?.sampleCount == 2)
        #expect(closeEnough(sixtyDay?.mean, 50))
    }

    @Test func coverageReflectsGaps() {
        // 3 recorded days in a 30-day window is coverage 0.1
        let series = [
            DatedValue(day: day(2026, 6, 10), value: 1),
            DatedValue(day: day(2026, 6, 20), value: 2),
            DatedValue(day: day(2026, 7, 1), value: 3),
        ]
        let baseline = MetricBaseline.compute(
            over: series, windowDays: 30, endingOn: day(2026, 7, 1), calendar: utcCalendar)
        #expect(closeEnough(baseline?.coverage, 0.1))
    }
}

/// What the builder does to cached records: which days count, how sleep
/// converts, and which metrics end up with a series at all.
@Suite struct BaselineBuilderTests {

    // fixed "now": midday on 18 Jul 2026
    private var now: Date { day(2026, 7, 18).addingTimeInterval(43200) }

    private func metricRecord(_ kind: MetricKind, on date: Date, value: Double) -> DailyMetricRecord {
        DailyMetricRecord(date: date, metricKind: kind.rawValue, value: value, unit: kind.unitLabel)
    }

    private func nightRecord(wakeDay: Date, asleep: TimeInterval, deep: TimeInterval?, rem: TimeInterval?, end: Date? = nil) -> SleepNightRecord {
        SleepNightRecord(night: SleepNight(
            wakeDay: wakeDay,
            start: wakeDay.addingTimeInterval(-28800),
            end: end ?? wakeDay.addingTimeInterval(-3600),
            asleep: asleep, deep: deep, rem: rem))
    }

    private func series(
        metrics: [DailyMetricRecord] = [],
        nights: [SleepNightRecord] = []
    ) -> [AnalyticMetric: [DatedValue]] {
        BaselineBuilder.dailySeries(metrics: metrics, nights: nights, asOf: now)
    }

    /// One metric's 30-day baseline, built the way every detector builds it:
    /// flatten the cache, then measure the window ending on that metric's own
    /// last complete day.
    private func thirtyDayBaseline(
        for metric: AnalyticMetric,
        metrics: [DailyMetricRecord] = [],
        nights: [SleepNightRecord] = []
    ) -> MetricBaseline? {
        guard let metricSeries = series(metrics: metrics, nights: nights)[metric] else {
            return nil
        }
        return MetricBaseline.compute(
            over: metricSeries,
            windowDays: 30,
            endingOn: metric.latestCompleteDay(asOf: now, calendar: utcCalendar),
            calendar: utcCalendar)
    }

    @Test func quantityBaselineExcludesToday() {
        // today's half-finished 100 must not join yesterday's 50
        let records = [
            metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 18), value: 100),
        ]
        let baseline = thirtyDayBaseline(for: .quantity(.restingHeartRate), metrics: records)

        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 50))
    }

    @Test func sleepBaselineIncludesThisMorning() {
        // 25200 s asleep is 7 h, waking today. That night is complete, so it counts.
        let nights = [nightRecord(wakeDay: day(2026, 7, 18), asleep: 25200, deep: nil, rem: nil)]
        let baseline = thirtyDayBaseline(for: .sleepDuration, nights: nights)

        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 7))
    }

    @Test func unknownStagesAreSkippedNotZero() {
        // one night with stages (5400 s deep is 1.5 h), one without. The
        // stageless night must not enter the deep series as a zero.
        let nights = [
            nightRecord(wakeDay: day(2026, 7, 17), asleep: 25200, deep: 5400, rem: 7200),
            nightRecord(wakeDay: day(2026, 7, 18), asleep: 27000, deep: nil, rem: nil),
        ]
        let built = series(nights: nights)

        #expect(built[.sleepDuration]?.count == 2)
        #expect(built[.deepSleepDuration]?.count == 1)
        #expect(closeEnough(built[.deepSleepDuration]?.first?.value, 1.5))
        #expect(closeEnough(built[.remSleepDuration]?.first?.value, 2))
    }

    @Test func everyQuantityMetricWithDataGetsASeries() {
        let records = MetricKind.allCases.map { kind in
            metricRecord(kind, on: day(2026, 7, 17), value: 10)
        }
        let built = series(metrics: records)

        for kind in MetricKind.allCases {
            #expect(built[.quantity(kind)] != nil)
        }
    }

    @Test func nightStillWithinSessionGapIsExcluded() {
        // woke 30 min before "now", so the aggregator could still merge more
        // sleep onto this night. It must not enter the series yet.
        let nights = [nightRecord(
            wakeDay: day(2026, 7, 18), asleep: 14400, deep: nil, rem: nil,
            end: now.addingTimeInterval(-1800))]

        #expect(series(nights: nights)[.sleepDuration] == nil)
    }

    @Test func metricsWithoutDataAreAbsent() {
        #expect(series().isEmpty)
    }

    @Test func seriesIsSortedOldestFirst() {
        // detectors depend on this order, so two runs over the same cache agree
        let records = [
            metricRecord(.hrv, on: day(2026, 7, 17), value: 55),
            metricRecord(.hrv, on: day(2026, 7, 15), value: 45),
            metricRecord(.hrv, on: day(2026, 7, 16), value: 50),
        ]
        let days = series(metrics: records)[.quantity(.hrv)]?.map(\.day)

        #expect(days == [day(2026, 7, 15), day(2026, 7, 16), day(2026, 7, 17)])
    }
}
