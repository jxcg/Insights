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

/// The OLS trend detector against hand-built series: known drifts must be
/// flagged with the right shape and horizon, and every flat, noisy, or
/// too-sparse series must stay silent.
@Suite struct TrendDetectorTests {

    // fixed "now": midday on 18 Jul 2026, so quantity windows end 17 Jul (today
    // still accumulating) and sleep windows end 18 Jul (the morning woken)
    private var now: Date { day(2026, 7, 18).addingTimeInterval(43200) }

    private func metricRecord(_ kind: MetricKind, on date: Date, value: Double) -> DailyMetricRecord {
        DailyMetricRecord(date: date, metricKind: kind.rawValue, value: value, unit: kind.unitLabel)
    }

    private func nightRecord(wakeDay: Date, asleep: TimeInterval) -> SleepNightRecord {
        SleepNightRecord(night: SleepNight(
            wakeDay: wakeDay,
            start: wakeDay.addingTimeInterval(-28800),
            end: wakeDay.addingTimeInterval(-3600),
            asleep: asleep, deep: nil, rem: nil))
    }

    /// A run of consecutive daily readings whose last value lands on `end` and
    /// each earlier one a day before it — the shape trend fits run over.
    private func quantitySeries(_ kind: MetricKind, endingOn end: Date, values: [Double]) -> [DailyMetricRecord] {
        values.enumerated().map { index, value in
            let offsetFromEnd = values.count - 1 - index
            let date = utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: end)!
            return metricRecord(kind, on: date, value: value)
        }
    }

    /// Consecutive nights of sleep in hours, last night waking on `end`.
    private func sleepSeries(endingOn end: Date, hours: [Double]) -> [SleepNightRecord] {
        hours.enumerated().map { index, value in
            let offsetFromEnd = hours.count - 1 - index
            let wakeDay = utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: end)!
            return nightRecord(wakeDay: wakeDay, asleep: value * 3600)
        }
    }

    @Test func risingSeriesIsFlaggedAsTrend() {
        // 7 days rising by 2/day: slope 2, change 12 over the window / mean 56 ≈ 21%
        let records = quantitySeries(
            .restingHeartRate, endingOn: day(2026, 7, 17),
            values: [50, 52, 54, 56, 58, 60, 62])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.type == .trend)
        #expect(finding.metric == .quantity(.restingHeartRate))
        #expect(finding.direction == .rising)
        #expect(finding.windowDays == 7)
        #expect(closeEnough(finding.magnitude, 12.0 / 56.0))
        #expect(closeEnough(finding.currentValue, 62))
        #expect(closeEnough(finding.baselineValue, 56))
        #expect(closeEnough(finding.confidence, 1.0))
    }

    @Test func flatSeriesStaysSilent() {
        // a perfectly level series has slope 0 — no drift to report
        let records = quantitySeries(
            .restingHeartRate, endingOn: day(2026, 7, 17),
            values: [55, 55, 55, 55, 55, 55, 55])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func noisyTrendlessSeriesStaysSilent() {
        // a symmetric zig-zag has plenty of movement but a net slope of 0
        let records = quantitySeries(
            .restingHeartRate, endingOn: day(2026, 7, 17),
            values: [50, 60, 50, 60, 50, 60, 50])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func driftJustBelowThresholdStaysSilent() {
        // slope 0.8/day: change 4.8 over the window / mean 102.4 ≈ 4.7%, under 5%
        let records = quantitySeries(
            .restingHeartRate, endingOn: day(2026, 7, 17),
            values: [100, 100.8, 101.6, 102.4, 103.2, 104, 104.8])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func driftJustAboveThresholdIsFlagged() {
        // slope 1/day: change 6 over the window / mean 103 ≈ 5.8%, just past 5%
        let records = quantitySeries(
            .restingHeartRate, endingOn: day(2026, 7, 17),
            values: [100, 101, 102, 103, 104, 105, 106])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        #expect(findings[0].windowDays == 7)
        #expect(closeEnough(findings[0].magnitude, 6.0 / 103.0))
    }

    @Test func fallingActivityTrendsDownAndCautions() {
        // steps sliding 400/day: a sustained activity decline is cautionary
        let records = quantitySeries(
            .steps, endingOn: day(2026, 7, 17),
            values: [12000, 11600, 11200, 10800, 10400, 10000, 9600])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.metric == .quantity(.steps))
        #expect(finding.direction == .falling)
        #expect(finding.tone == .cautionary)
        #expect(closeEnough(finding.magnitude, 2400.0 / 10800.0))
        #expect(closeEnough(finding.currentValue, 9600))
        #expect(closeEnough(finding.baselineValue, 10800))
    }

    @Test func longestQualifyingWindowIsChosen() {
        // 90 days rising ~1.5%/day: the 7, 21 and 90-day windows each clear the
        // threshold, so the most sustained horizon (90) must win
        let values = (0..<90).map { 50 * pow(1.015, Double($0)) }
        let records = quantitySeries(
            .restingHeartRate, endingOn: day(2026, 7, 17), values: values)
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        #expect(findings[0].windowDays == 90)
        #expect(findings[0].direction == .rising)
        #expect(closeEnough(findings[0].confidence, 1.0))
    }

    @Test func sparseWindowBelowCoverageStaysSilent() {
        // 3 steeply rising points: coverage 3/7 sits under the floor, so even a
        // strong slope is not a defensible trend and stays silent
        let records = [
            metricRecord(.restingHeartRate, on: day(2026, 7, 15), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 16), value: 60),
            metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 70),
        ]
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func confidenceMatchesWindowCoverage() {
        // 5 readings across the 7-day window → coverage, and so confidence, 5/7
        let records = [
            metricRecord(.restingHeartRate, on: day(2026, 7, 13), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 14), value: 53),
            metricRecord(.restingHeartRate, on: day(2026, 7, 15), value: 56),
            metricRecord(.restingHeartRate, on: day(2026, 7, 16), value: 59),
            metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 62),
        ]
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        #expect(findings[0].windowDays == 7)
        #expect(closeEnough(findings[0].confidence, 5.0 / 7.0))
    }

    @Test func toneFollowsMetricAndDirection() {
        // rising HRV is a good sign; falling steps and rising resting HR are not
        let records = quantitySeries(
            .hrv, endingOn: day(2026, 7, 17), values: [40, 42, 44, 46, 48, 50, 52])
            + quantitySeries(
                .steps, endingOn: day(2026, 7, 17),
                values: [12000, 11600, 11200, 10800, 10400, 10000, 9600])
            + quantitySeries(
                .restingHeartRate, endingOn: day(2026, 7, 17),
                values: [50, 52, 54, 56, 58, 60, 62])
        let findings = TrendDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 3)
        let hrv = findings.first { $0.metric == .quantity(.hrv) }
        let steps = findings.first { $0.metric == .quantity(.steps) }
        let restingHeartRate = findings.first { $0.metric == .quantity(.restingHeartRate) }
        #expect(hrv?.direction == .rising)
        #expect(hrv?.tone == .positive)
        #expect(steps?.direction == .falling)
        #expect(steps?.tone == .cautionary)
        #expect(restingHeartRate?.direction == .rising)
        #expect(restingHeartRate?.tone == .cautionary)
    }

    @Test func sleepDurationDownTrendIsFlagged() {
        // sleep judged on the window ending today; 7 nights sliding 0.3 h/night
        let nights = sleepSeries(
            endingOn: day(2026, 7, 18),
            hours: [8.0, 7.7, 7.4, 7.1, 6.8, 6.5, 6.2])
        let findings = TrendDetector.detect(
            metrics: [], nights: nights, asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.metric == .sleepDuration)
        #expect(finding.direction == .falling)
        #expect(finding.tone == .cautionary)
        #expect(finding.windowDays == 7)
    }
}
