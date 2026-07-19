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

/// The rolling mean/SD maths checked against values computed by hand.
@Suite struct BaselineMathTests {

    @Test func fiveDayMeanAndSpread() {
        // 50, 52, 54, 56, 58 → mean 54; squared deviations 16+4+0+4+16 = 40,
        // sample variance 40/4 = 10, SD √10
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
        // 30-day window ending 1 Jul spans 2 Jun – 1 Jul, so 1 Jun must not count:
        // remaining 10 and 20 → mean 15, deviations ±5, variance 50/1, SD √50
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

    @Test func sixtyDayWindowReachesFurtherBack() {
        // a value 40 days old is outside the 30-day window but inside the 60-day
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
        // 3 recorded days in a 30-day window → coverage 0.1
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

/// The builder's policy over the cached records: which days count, how sleep
/// converts, and that every metric with data gets a baseline.
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

    @Test func quantityBaselineExcludesToday() {
        // today's half-finished 100 must not join yesterday's 50
        let records = [
            metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 18), value: 100),
        ]
        let baselines = BaselineBuilder.build(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        let baseline = baselines[.quantity(.restingHeartRate)]?.thirtyDay
        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 50))
    }

    @Test func sleepBaselineIncludesThisMorning() {
        // 25200 s asleep = 7 h, waking today — complete, so it counts
        let nights = [nightRecord(wakeDay: day(2026, 7, 18), asleep: 25200, deep: nil, rem: nil)]
        let baselines = BaselineBuilder.build(
            metrics: [], nights: nights, asOf: now, calendar: utcCalendar)

        let baseline = baselines[.sleepDuration]?.thirtyDay
        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 7))
    }

    @Test func unknownStagesAreSkippedNotZero() {
        // one night with stages (5400 s deep = 1.5 h), one without: the
        // stageless night must not enter the deep series as a zero
        let nights = [
            nightRecord(wakeDay: day(2026, 7, 17), asleep: 25200, deep: 5400, rem: 7200),
            nightRecord(wakeDay: day(2026, 7, 18), asleep: 27000, deep: nil, rem: nil),
        ]
        let baselines = BaselineBuilder.build(
            metrics: [], nights: nights, asOf: now, calendar: utcCalendar)

        #expect(baselines[.sleepDuration]?.thirtyDay?.sampleCount == 2)
        #expect(baselines[.deepSleepDuration]?.thirtyDay?.sampleCount == 1)
        #expect(closeEnough(baselines[.deepSleepDuration]?.thirtyDay?.mean, 1.5))
        #expect(closeEnough(baselines[.remSleepDuration]?.thirtyDay?.mean, 2))
    }

    @Test func everyQuantityMetricWithDataGetsABaseline() {
        let records = MetricKind.allCases.map { kind in
            metricRecord(kind, on: day(2026, 7, 17), value: 10)
        }
        let baselines = BaselineBuilder.build(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        for kind in MetricKind.allCases {
            #expect(baselines[.quantity(kind)]?.thirtyDay != nil)
        }
    }

    @Test func nightStillWithinSessionGapIsExcluded() {
        // woke 30 min before "now": the aggregator could still merge more
        // sleep onto this night, so it must not enter the baseline yet
        let nights = [nightRecord(
            wakeDay: day(2026, 7, 18), asleep: 14400, deep: nil, rem: nil,
            end: now.addingTimeInterval(-1800))]
        let baselines = BaselineBuilder.build(
            metrics: [], nights: nights, asOf: now, calendar: utcCalendar)
        #expect(baselines[.sleepDuration] == nil)
    }

    @Test func metricsWithoutDataAreAbsent() {
        let baselines = BaselineBuilder.build(
            metrics: [], nights: [], asOf: now, calendar: utcCalendar)
        #expect(baselines.isEmpty)
    }

    @Test func onlyOldDataStillYieldsSixtyDayBaseline() {
        // data 45 days back: outside the 30-day window, inside the 60-day —
        // the metric still gets an entry, with just the longer horizon filled
        let records = [metricRecord(.hrv, on: day(2026, 6, 3), value: 55)]
        let baselines = BaselineBuilder.build(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(baselines[.quantity(.hrv)]?.thirtyDay == nil)
        #expect(baselines[.quantity(.hrv)]?.sixtyDay?.sampleCount == 1)
    }
}
