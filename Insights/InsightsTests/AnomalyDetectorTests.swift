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

/// The z-score detector against hand-built series: known anomalies must be
/// flagged with the right shape, and every null case must stay silent.
@Suite struct AnomalyDetectorTests {

    // fixed "now": midday on 18 Jul 2026, so yesterday (17 Jul) is the judged
    // day for quantities and 18 Jul the judged morning for sleep
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

    /// Two prior days at 47 and 53 give mean 50 and sample SD √18 ≈ 4.243 —
    /// the baseline used by most cases below.
    private func priorDays(_ kind: MetricKind) -> [DailyMetricRecord] {
        [
            metricRecord(kind, on: day(2026, 7, 15), value: 47),
            metricRecord(kind, on: day(2026, 7, 16), value: 53),
        ]
    }

    @Test func spikeAboveBaselineIsFlagged() {
        // judged 60 vs mean 50, SD √18: z = 10/√18 ≈ 2.36, past the threshold
        let records = priorDays(.restingHeartRate)
            + [metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 60)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.type == .anomaly)
        #expect(finding.metric == .quantity(.restingHeartRate))
        #expect(finding.direction == .rising)
        #expect(closeEnough(finding.currentValue, 60))
        #expect(closeEnough(finding.baselineValue, 50))
        #expect(closeEnough(finding.magnitude, 10 / 18.0.squareRoot()))
        #expect(finding.windowDays == AnomalyDetector.baselineWindowDays)
    }

    @Test func usualValueStaysSilent() {
        // judged 50 equals the mean: z = 0
        let records = priorDays(.restingHeartRate)
            + [metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 50)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func modestDeviationBelowThresholdStaysSilent() {
        // judged 54: z = 4/√18 ≈ 0.94, inside the threshold
        let records = priorDays(.restingHeartRate)
            + [metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 54)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func constantHistoryHasNoSpreadSoStaysSilent() {
        // identical prior days give SD 0 — no defensible z-score, so silence
        let records = [
            metricRecord(.restingHeartRate, on: day(2026, 7, 15), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 16), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 80),
        ]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func singlePriorDayStaysSilent() {
        // one prior reading has no spread to judge against
        let records = [
            metricRecord(.restingHeartRate, on: day(2026, 7, 16), value: 50),
            metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 80),
        ]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func noReadingOnJudgedDayStaysSilent() {
        // history exists but yesterday has no value — nothing to judge
        let findings = AnomalyDetector.detect(
            metrics: priorDays(.restingHeartRate), nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func judgedValueExcludedFromItsOwnBaseline() {
        // a huge spike must be judged against mean 50, not a mean it inflated
        let records = priorDays(.restingHeartRate)
            + [metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 100)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        #expect(closeEnough(findings.first?.baselineValue, 50))
    }

    @Test func quantitySpikeTodayIsNotJudgedYet() {
        // today is still accumulating: a spike on 18 Jul must wait for tomorrow
        let records = priorDays(.restingHeartRate)
            + [metricRecord(.restingHeartRate, on: day(2026, 7, 18), value: 100)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }

    @Test func shortSleepThisMorningIsFlagged() {
        // prior nights 6 h and 8 h: mean 7, SD √2; last night 4 h → z ≈ −2.12
        let nights = [
            nightRecord(wakeDay: day(2026, 7, 16), asleep: 21600),
            nightRecord(wakeDay: day(2026, 7, 17), asleep: 28800),
            nightRecord(wakeDay: day(2026, 7, 18), asleep: 14400),
        ]
        let findings = AnomalyDetector.detect(
            metrics: [], nights: nights, asOf: now, calendar: utcCalendar)

        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.metric == .sleepDuration)
        #expect(finding.direction == .falling)
        #expect(finding.tone == .cautionary)
        #expect(closeEnough(finding.currentValue, 4))
        #expect(closeEnough(finding.magnitude, 3 / 2.0.squareRoot()))
    }

    @Test func confidenceMatchesBaselineCoverage() {
        // 2 recorded days in the 30-day baseline window → coverage 2/30
        let records = priorDays(.restingHeartRate)
            + [metricRecord(.restingHeartRate, on: day(2026, 7, 17), value: 60)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)
        #expect(closeEnough(findings.first?.confidence, 2.0 / 30.0))
    }

    @Test func toneFollowsMetricAndDirection() {
        // falling HRV is a bad sign; unusually high steps a good one
        let records = priorDays(.hrv)
            + [metricRecord(.hrv, on: day(2026, 7, 17), value: 40)]
            + priorDays(.steps)
            + [metricRecord(.steps, on: day(2026, 7, 17), value: 60)]
        let findings = AnomalyDetector.detect(
            metrics: records, nights: [], asOf: now, calendar: utcCalendar)

        #expect(findings.count == 2)
        let hrvFinding = findings.first { $0.metric == .quantity(.hrv) }
        let stepsFinding = findings.first { $0.metric == .quantity(.steps) }
        #expect(hrvFinding?.direction == .falling)
        #expect(hrvFinding?.tone == .cautionary)
        #expect(stepsFinding?.direction == .rising)
        #expect(stepsFinding?.tone == .positive)
    }
}
