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

/// The correlation detector against hand-built series. Every r quoted in these
/// tests was computed independently of the detector, so a change to the maths
/// shows up as a failure rather than being silently blessed.
@Suite struct CorrelationDetectorTests {

    // fixed "now": midday on 18 Jul 2026, so quantity outcomes are paired up to
    // 17 Jul (today still accumulating) and sleep outcomes up to 18 Jul
    private var now: Date { day(2026, 7, 18).addingTimeInterval(43200) }

    /// 14 nights of varied sleep, the driver behind most of these cases.
    private let sleepHours = [5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0, 8.5,
                              5.2, 6.2, 7.2, 8.2, 6.8, 7.8]

    private func metricRecord(_ kind: MetricKind, on date: Date, value: Double) -> DailyMetricRecord {
        DailyMetricRecord(date: date, metricKind: kind.rawValue, value: value, unit: kind.unitLabel)
    }

    /// A run of consecutive daily readings whose last value lands on `end`.
    private func quantitySeries(
        _ kind: MetricKind, endingOn end: Date, values: [Double]
    ) -> [DailyMetricRecord] {
        values.enumerated().map { index, value in
            let offsetFromEnd = values.count - 1 - index
            let date = utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: end)!
            return metricRecord(kind, on: date, value: value)
        }
    }

    /// Consecutive nights, last night waking on `end`. Deep hours are supplied
    /// per night where a test needs the deep-sleep series.
    private func sleepSeries(
        endingOn end: Date, hours: [Double], deepHours: [Double]? = nil
    ) -> [SleepNightRecord] {
        hours.enumerated().map { index, value in
            let offsetFromEnd = hours.count - 1 - index
            let wakeDay = utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: end)!
            return SleepNightRecord(night: SleepNight(
                wakeDay: wakeDay,
                start: wakeDay.addingTimeInterval(-28800),
                end: wakeDay.addingTimeInterval(-3600),
                asleep: value * 3600,
                deep: deepHours.map { $0[index] * 3600 },
                rem: nil))
        }
    }

    @Test func plantedSleepToHrvCorrelationIsFound() {
        // HRV built as an exact linear response to that night's sleep: r = 1
        let hrvValues = sleepHours.map { 10 + 5 * $0 }
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(.hrv, endingOn: day(2026, 7, 17), values: hrvValues),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: sleepHours),
            asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.type == .correlation)
        #expect(finding.metric == .quantity(.hrv))
        #expect(finding.drivingMetric == .sleepDuration)
        #expect(finding.direction == .rising)
        #expect(finding.tone == .neutral)
        #expect(closeEnough(finding.magnitude, 1.0))
        #expect(finding.windowDays == 90)
        #expect(closeEnough(finding.confidence, 14.0 / 45.0))
        // the outcome across the paired days: latest reading, and their mean
        #expect(closeEnough(finding.currentValue, 49))
        #expect(closeEnough(finding.baselineValue, hrvValues.reduce(0, +) / 14))
        // a same-day pairing must never be worded as one day following another
        #expect(finding.plainStatement.contains("on days with"))
    }

    @Test func confidenceStopsClimbingOncePairsAreEnough() {
        // 50 pairs is past the point where extra days buy any more certainty,
        // so the link reports full confidence rather than 50/45
        let hours = (0..<50).map { 5.0 + Double($0 % 8) * 0.5 }
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(
                .hrv, endingOn: day(2026, 7, 17), values: hours.map { 10 + 5 * $0 }),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: hours),
            asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        #expect(closeEnough(findings[0].confidence, 1.0))
    }

    @Test func uncorrelatedSeriesStaySilent() {
        // the same HRV readings as a related case would use, reordered until they
        // carry no relationship to sleep at all: r = 0.0004
        let hrvValues: [Double] = [38, 42, 45, 47, 52, 49, 44, 41, 60, 58, 56, 53, 55, 50]
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(.hrv, endingOn: day(2026, 7, 17), values: hrvValues),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: sleepHours),
            asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func pairCountMinimumIsABoundary() {
        // a flawless relationship on 13 pairs is still too little to report;
        // the 14th pair is what makes the same relationship reportable
        func findings(pairCount: Int) -> [Finding] {
            let hours = Array(sleepHours.prefix(pairCount))
            return CorrelationDetector.detect(
                metrics: quantitySeries(
                    .hrv, endingOn: day(2026, 7, 17), values: hours.map { 10 + 5 * $0 }),
                nights: sleepSeries(endingOn: day(2026, 7, 17), hours: hours),
                asOf: now, calendar: utcCalendar)
        }
        #expect(findings(pairCount: 13).isEmpty)
        #expect(findings(pairCount: 14).count == 1)
    }

    @Test func correlationJustBelowThresholdStaysSilent() {
        // r = 0.3848 across a full 14 pairs — strength, not sample size, rejects it
        let hrvValues: [Double] = [56, 46, 60, 50, 64, 54, 68, 58, 57, 49, 65, 57, 63, 55]
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(.hrv, endingOn: day(2026, 7, 17), values: hrvValues),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: sleepHours),
            asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func correlationJustAboveThresholdIsFlagged() {
        // the same shape nudged over the line: r = 0.415094
        let hrvValues: [Double] = [56, 46, 60, 50, 64, 54, 68, 58, 56, 49, 64, 57, 63, 56]
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(.hrv, endingOn: day(2026, 7, 17), values: hrvValues),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: sleepHours),
            asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        #expect(closeEnough(findings[0].magnitude, 0.41509361330567046))
    }

    @Test func suppressedHrvAlongsideHigherRestingHeartRateReadsAsFalling() {
        // the illness pattern the ticket names: as resting HR climbs, HRV drops
        let restingValues: [Double] = [48, 50, 52, 54, 56, 58, 60, 62, 49, 53, 57, 61, 55, 59]
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(.restingHeartRate, endingOn: day(2026, 7, 17), values: restingValues)
                + quantitySeries(
                    .hrv, endingOn: day(2026, 7, 17), values: restingValues.map { 100 - $0 }),
            nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.metric == .quantity(.hrv))
        #expect(finding.drivingMetric == .quantity(.restingHeartRate))
        #expect(finding.direction == .falling)
        #expect(finding.tone == .neutral)
        #expect(closeEnough(finding.magnitude, 1.0))
        #expect(finding.plainStatement.contains("lower"))
    }

    // 15 days of active energy with no day-to-day pattern of its own, so a
    // lagged pairing cannot pick up the driver's own rhythm by accident
    private let activeEnergyValues: [Double] = [600, 900, 300, 300, 900, 750, 450, 600,
                                                450, 750, 750, 300, 300, 900, 900]

    @Test func activityToDeepSleepIsFoundAtLagOne() {
        // each night's deep sleep responds to the PREVIOUS day's activity
        var deepHours: [Double] = [1.0]   // first night has no prior day: unpaired
        deepHours += activeEnergyValues.dropLast().map { 0.5 + $0 / 450 }
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(
                .activeEnergy, endingOn: day(2026, 7, 18), values: activeEnergyValues),
            nights: sleepSeries(
                endingOn: day(2026, 7, 18),
                hours: Array(repeating: 7.5, count: 15),
                deepHours: deepHours),
            asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.metric == .deepSleepDuration)
        #expect(finding.drivingMetric == .quantity(.activeEnergy))
        #expect(finding.direction == .rising)
        #expect(closeEnough(finding.magnitude, 1.0))
        #expect(closeEnough(finding.confidence, 14.0 / 45.0))
        #expect(finding.plainStatement.contains("the day after"))
    }

    @Test func sameDayRelationshipIsNotFoundAtALaggedPairing() {
        // deep sleep planted against the SAME day's activity. Paired at the
        // hypothesis' lag of one day the relationship all but vanishes
        // (r = -0.026 over a full 14 pairs), so the detector must stay silent —
        // proof the lag is actually applied rather than assumed away.
        let deepHours = activeEnergyValues.map { 0.5 + $0 / 450 }
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(
                .activeEnergy, endingOn: day(2026, 7, 18), values: activeEnergyValues),
            nights: sleepSeries(
                endingOn: day(2026, 7, 18),
                hours: Array(repeating: 7.5, count: 15),
                deepHours: deepHours),
            asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func flatOutcomeStaysSilent() {
        // an outcome that never moves cannot move with anything
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(
                .hrv, endingOn: day(2026, 7, 17), values: Array(repeating: 50, count: 14)),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: sleepHours),
            asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func daysOutsideTheWindowAreExcluded() {
        // a flawless relationship, but from February — outside the 90-day window
        // that ends 17 Jul, so no pairs survive to be correlated
        let end = day(2026, 2, 20)
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(.hrv, endingOn: end, values: sleepHours.map { 10 + 5 * $0 }),
            nights: sleepSeries(endingOn: end, hours: sleepHours),
            asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func daysMissingOnOneSideMakeNoPair() {
        // 14 nights of sleep, but HRV recorded on only the last 10 of those days:
        // the 4 half-covered days cannot pair, leaving too few to report
        let findings = CorrelationDetector.detect(
            metrics: quantitySeries(
                .hrv, endingOn: day(2026, 7, 17),
                values: sleepHours.suffix(10).map { 10 + 5 * $0 }),
            nights: sleepSeries(endingOn: day(2026, 7, 17), hours: sleepHours),
            asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }
}
