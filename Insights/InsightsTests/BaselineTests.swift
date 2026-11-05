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

// one reading per day, consecutive, starting on `firstDay`
private func consecutiveDays(from firstDay: Date, values: [Double]) -> [DatedValue] {
    values.enumerated().map { offset, value in
        DatedValue(
            day: utcCalendar.date(byAdding: .day, value: offset, to: firstDay)!,
            value: value)
    }
}

/// The mean and spread maths, checked against values worked out by hand.
///
/// Every expected number has its working in a comment. A 30-day window ending
/// 1 Jul runs 2 Jun to 1 Jul inclusive; most cases lean on that.
@Suite struct BaselineMathTests {

    private func thirtyDayBaseline(_ series: [DatedValue], endingOn endDay: Date) -> MetricBaseline? {
        MetricBaseline.compute(over: series, windowDays: 30, endingOn: endDay, calendar: utcCalendar)
    }

    @Test func meanAndSpreadOfFiveRestingHeartRates() {
        // 52, 54, 55, 53, 56 bpm: sum 270, mean 54.
        // deviations -2, 0, 1, -1, 2; squared 4 + 0 + 1 + 1 + 4 = 10.
        // sample variance 10 / (5 - 1) = 2.5, SD √2.5 = 1.5811388300841898.
        let series = consecutiveDays(from: day(2026, 6, 27), values: [52, 54, 55, 53, 56])
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))

        #expect(closeEnough(baseline?.mean, 54))
        #expect(closeEnough(baseline?.standardDeviation, 1.5811388300841898))
        #expect(baseline?.sampleCount == 5)
        #expect(closeEnough(baseline?.coverage, 5.0 / 30.0))
    }

    @Test func oneDayHasAMeanButNoSpread() {
        // a single reading has nothing to vary against, so SD is unknown,
        // not zero
        let series = [DatedValue(day: day(2026, 7, 1), value: 62)]
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))

        #expect(closeEnough(baseline?.mean, 62))
        #expect(baseline?.standardDeviation == nil)
        #expect(baseline?.sampleCount == 1)
    }

    @Test func identicalDaysHaveZeroSpread() {
        // three days at 54 bpm: every deviation is 0, so SD is a real 0, not
        // nil. Callers dividing by it must guard against 0 themselves.
        let series = consecutiveDays(from: day(2026, 6, 29), values: [54, 54, 54])
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))

        #expect(baseline?.standardDeviation == 0)
    }

    @Test func anEmptyWindowGivesNoBaseline() {
        #expect(thirtyDayBaseline([], endingOn: day(2026, 7, 1)) == nil)
    }

    @Test func aWindowWithNoReadingsInsideItGivesNoBaseline() {
        // readings exist, but all of them fall before 2 Jun
        let series = [DatedValue(day: day(2026, 5, 1), value: 55)]
        #expect(thirtyDayBaseline(series, endingOn: day(2026, 7, 1)) == nil)
    }

    @Test func theDayBeforeTheWindowIsLeftOut() {
        // 1 Jun sits one day outside the window, so its 120 ms must not count.
        // 2 Jun is the first day inside it and does.
        // 52 and 58 ms: mean 55, deviations ±3, squared 9 + 9 = 18.
        // sample variance 18 / (2 - 1) = 18, SD √18 = 4.242640687119285.
        let series = [
            DatedValue(day: day(2026, 6, 1), value: 120),
            DatedValue(day: day(2026, 6, 2), value: 52),
            DatedValue(day: day(2026, 7, 1), value: 58),
        ]
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))

        #expect(baseline?.sampleCount == 2)
        #expect(closeEnough(baseline?.mean, 55))
        #expect(closeEnough(baseline?.standardDeviation, 4.242640687119285))
    }

    @Test func daysAfterTheWindowAreLeftOut() {
        // a window ending 30 Jun must ignore 1 Jul, even though it is the
        // newest reading
        let series = [
            DatedValue(day: day(2026, 6, 30), value: 54),
            DatedValue(day: day(2026, 7, 1), value: 70),
        ]
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 6, 30))

        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 54))
    }

    @Test func aReadingLateInTheDayStillCountsForThatDay() {
        // stored at 18:00 on the window's last day, which is still that day
        let evening = day(2026, 7, 1).addingTimeInterval(18 * 3600)
        let series = [DatedValue(day: evening, value: 54)]
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))

        #expect(baseline?.sampleCount == 1)
    }

    @Test func aLongerWindowReachesFurtherBack() {
        // 22 May is 40 days before 1 Jul: outside a 30-day window (from 2 Jun),
        // inside a 60-day one (from 3 May).
        // 30-day: only 54 bpm, mean 54. 60-day: 58 and 54, mean 56.
        let series = [
            DatedValue(day: day(2026, 5, 22), value: 58),
            DatedValue(day: day(2026, 7, 1), value: 54),
        ]
        let thirtyDay = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))
        let sixtyDay = MetricBaseline.compute(
            over: series, windowDays: 60, endingOn: day(2026, 7, 1), calendar: utcCalendar)

        #expect(thirtyDay?.sampleCount == 1)
        #expect(closeEnough(thirtyDay?.mean, 54))
        #expect(sixtyDay?.sampleCount == 2)
        #expect(closeEnough(sixtyDay?.mean, 56))
    }

    @Test func coverageIsTheShareOfDaysWithAReading() {
        // 3 recorded days out of 30 is coverage 3 / 30 = 0.1
        let series = [
            DatedValue(day: day(2026, 6, 10), value: 51),
            DatedValue(day: day(2026, 6, 20), value: 53),
            DatedValue(day: day(2026, 7, 1), value: 55),
        ]
        let baseline = thirtyDayBaseline(series, endingOn: day(2026, 7, 1))

        #expect(closeEnough(baseline?.coverage, 0.1))
    }
}

/// What the builder does to cached records before any maths runs: which days
/// count, how sleep converts to hours, and which metrics get a series at all.
@Suite struct BaselineBuilderTests {

    // fixed "now": midday on 18 Jul 2026. Quantities are judged up to 17 Jul;
    // last night is the one ending on the morning of 18 Jul.
    private let now = day(2026, 7, 18).addingTimeInterval(12 * 3600)

    private func metricRecord(_ kind: MetricKind, on date: Date, value: Double) -> DailyMetricRecord {
        DailyMetricRecord(date: date, metricKind: kind.rawValue, value: value, unit: kind.unitLabel)
    }

    // in bed at 23:00 the evening before `wakeDay`, awake once `asleep` has
    // passed, unless `end` says otherwise
    private func nightRecord(
        wakeDay: Date,
        asleep: TimeInterval,
        deep: TimeInterval? = nil,
        rem: TimeInterval? = nil,
        end: Date? = nil
    ) -> SleepNightRecord {
        let bedtime = wakeDay.addingTimeInterval(-3600)
        return SleepNightRecord(night: SleepNight(
            wakeDay: wakeDay,
            start: bedtime,
            end: end ?? bedtime.addingTimeInterval(asleep),
            asleep: asleep, deep: deep, rem: rem))
    }

    private func series(
        metrics: [DailyMetricRecord] = [],
        nights: [SleepNightRecord] = []
    ) -> [AnalyticMetric: [DatedValue]] {
        BaselineBuilder.dailySeries(metrics: metrics, nights: nights, asOf: now)
    }

    /// A metric's 30-day baseline built the way every detector builds one:
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

    @Test func todaysUnfinishedStepsStayOutOfTheBaseline() {
        // by midday only 3,100 steps are in; yesterday's 8,640 is the whole
        // baseline
        let records = [
            metricRecord(.steps, on: day(2026, 7, 17), value: 8640),
            metricRecord(.steps, on: day(2026, 7, 18), value: 3100),
        ]
        let baseline = thirtyDayBaseline(for: .quantity(.steps), metrics: records)

        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 8640))
    }

    @Test func lastNightCountsOnceItHasEnded() {
        // 23:00 to 06:12 is 25,920 s asleep, 25,920 / 3,600 = 7.2 h. Waking at
        // 06:12 is almost six hours before midday, well past the session gap.
        let nights = [nightRecord(wakeDay: day(2026, 7, 18), asleep: 25920)]
        let baseline = thirtyDayBaseline(for: .sleepDuration, nights: nights)

        #expect(baseline?.sampleCount == 1)
        #expect(closeEnough(baseline?.mean, 7.2))
    }

    @Test func aNightStillWithinTheSessionGapIsLeftOut() {
        // woke at 11:30, half an hour ago: more sleep could still join this
        // night, so it must not enter the series yet
        let nights = [nightRecord(
            wakeDay: day(2026, 7, 18), asleep: 25920,
            end: now.addingTimeInterval(-1800))]

        #expect(series(nights: nights)[.sleepDuration] == nil)
    }

    @Test func aNightEndingExactlyTheSessionGapAgoCounts() {
        // woke at 10:00, exactly 7,200 s before midday: the gap has passed
        let nights = [nightRecord(
            wakeDay: day(2026, 7, 18), asleep: 25920,
            end: now.addingTimeInterval(-SleepNightAggregator.sessionGap))]

        #expect(series(nights: nights)[.sleepDuration]?.count == 1)
    }

    @Test func stageHoursConvertFromSeconds() {
        // 4,320 s deep = 1.2 h, 5,940 s REM = 1.65 h, inside a 7.2 h night
        let nights = [nightRecord(
            wakeDay: day(2026, 7, 17), asleep: 25920, deep: 4320, rem: 5940)]
        let built = series(nights: nights)

        #expect(closeEnough(built[.sleepDuration]?.first?.value, 7.2))
        #expect(closeEnough(built[.deepSleepDuration]?.first?.value, 1.2))
        #expect(closeEnough(built[.remSleepDuration]?.first?.value, 1.65))
    }

    @Test func unknownStagesAreSkippedNotCountedAsZero() {
        // the second night recorded no stages at all. It still counts for
        // sleep duration, but must not join the stage series as a zero.
        let nights = [
            nightRecord(wakeDay: day(2026, 7, 16), asleep: 25920, deep: 4320, rem: 5940),
            nightRecord(wakeDay: day(2026, 7, 17), asleep: 27000),
        ]
        let built = series(nights: nights)

        #expect(built[.sleepDuration]?.count == 2)
        #expect(built[.deepSleepDuration]?.count == 1)
        #expect(built[.remSleepDuration]?.count == 1)
        #expect(closeEnough(built[.deepSleepDuration]?.first?.value, 1.2))
    }

    @Test func aRecordedZeroIsKeptAsAZero() {
        // stages were recorded, just no REM: that is a real 0, unlike nil
        let nights = [nightRecord(
            wakeDay: day(2026, 7, 17), asleep: 25920, deep: 4320, rem: 0)]
        let rem = series(nights: nights)[.remSleepDuration]

        #expect(rem?.count == 1)
        #expect(rem?.first?.value == 0)
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

    @Test func aRecordForAnUnknownMetricIsIgnored() {
        // a metric name this build does not know, perhaps from a newer version
        // of the cache
        let stray = DailyMetricRecord(
            date: day(2026, 7, 17), metricKind: "bloodGlucose", value: 5.4, unit: "mmol/L")

        #expect(series(metrics: [stray]).isEmpty)
    }

    @Test func anEmptyCacheGivesNoSeries() {
        #expect(series().isEmpty)
    }

    @Test func seriesComeOutOldestFirst() {
        // records arrive from the cache in no promised order; detectors depend
        // on this one, so two runs over the same cache agree
        let records = [
            metricRecord(.hrv, on: day(2026, 7, 17), value: 58),
            metricRecord(.hrv, on: day(2026, 7, 15), value: 49),
            metricRecord(.hrv, on: day(2026, 7, 16), value: 53),
        ]
        let days = series(metrics: records)[.quantity(.hrv)]?.map(\.day)

        #expect(days == [day(2026, 7, 15), day(2026, 7, 16), day(2026, 7, 17)])
    }
}
