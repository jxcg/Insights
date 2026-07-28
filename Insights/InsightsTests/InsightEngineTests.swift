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

/// The whole engine over one synthetic month, checked end to end. The detectors
/// have their own suites for whether they find the right things; these tests
/// are about what survives being ranked together and handed on.
@Suite struct InsightEngineTests {

    // fixed "now": midday on 18 Jul 2026, so quantities are judged to 17 Jul
    // and last night is the night ending 18 Jul
    private var now: Date { day(2026, 7, 18).addingTimeInterval(43200) }

    private func quantitySeries(
        _ kind: MetricKind, endingOn end: Date, values: [Double]
    ) -> [DailyMetricRecord] {
        values.enumerated().map { index, value in
            let offsetFromEnd = values.count - 1 - index
            let date = utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: end)!
            return DailyMetricRecord(
                date: date, metricKind: kind.rawValue, value: value, unit: kind.unitLabel)
        }
    }

    private func sleepSeries(endingOn end: Date, hours: [Double]) -> [SleepNightRecord] {
        hours.enumerated().map { index, value in
            let offsetFromEnd = hours.count - 1 - index
            let wakeDay = utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: end)!
            return SleepNightRecord(night: SleepNight(
                wakeDay: wakeDay,
                start: wakeDay.addingTimeInterval(-28800),
                end: wakeDay.addingTimeInterval(-3600),
                asleep: value * 3600,
                deep: nil,
                rem: nil))
        }
    }

    /// A month with something for every stage to find: nights that vary, HRV
    /// that has tracked those nights all month and then collapses yesterday,
    /// resting heart rate climbing steadily, and a single big day of steps.
    private var sleepHours: [Double] {
        let cycle: [Double] = [6.0, 7.5, 8.0, 6.5, 7.0, 8.5, 6.8, 7.2, 5.5, 7.8]
        return cycle + cycle + cycle
    }

    private var syntheticMonth: (metrics: [DailyMetricRecord], nights: [SleepNightRecord]) {
        // HRV has tracked sleep exactly, up to yesterday's collapse
        var hrvValues = sleepHours.dropLast().map { 10 + 5 * $0 }
        hrvValues[hrvValues.count - 1] = 20

        let restingValues = (0..<30).map { 50 + Double($0) * 0.31 }

        let stepsCycle: [Double] = [8500, 9200, 8800, 9500, 9000]
        var stepsValues = stepsCycle + stepsCycle + stepsCycle + stepsCycle + stepsCycle + stepsCycle
        stepsValues[stepsValues.count - 1] = 11000

        let metrics = quantitySeries(.hrv, endingOn: day(2026, 7, 17), values: hrvValues)
            + quantitySeries(.restingHeartRate, endingOn: day(2026, 7, 17), values: restingValues)
            + quantitySeries(.steps, endingOn: day(2026, 7, 17), values: stepsValues)
        return (metrics, sleepSeries(endingOn: day(2026, 7, 18), hours: sleepHours))
    }

    @Test func aBusyDayIsCutToFiveAndEveryStageIsRepresented() {
        let month = syntheticMonth
        let findings = InsightEngine.dailyFindings(
            metrics: month.metrics, nights: month.nights, asOf: now, calendar: utcCalendar)

        #expect(findings.count == 5)
        // the point of ranking across stages rather than within them: a day's
        // list can hold yesterday's news, a drift, and a standing relationship
        #expect(Set(findings.map(\.type)) == [.anomaly, .trend, .correlation])
    }

    @Test func theSharpestNewsOfTheDayLeads() {
        // HRV collapsing to 20 against a usual mid-forties is the largest
        // surprise on offer, and a cautionary one
        let month = syntheticMonth
        let findings = InsightEngine.dailyFindings(
            metrics: month.metrics, nights: month.nights, asOf: now, calendar: utcCalendar)

        #expect(findings.first?.metric == .quantity(.hrv))
        #expect(findings.first?.type == .anomaly)
        #expect(findings.first?.direction == .falling)
        #expect(findings.first?.tone == .cautionary)
    }

    @Test func theListOnlyEverGetsWeaker() {
        let month = syntheticMonth
        let findings = InsightEngine.dailyFindings(
            metrics: month.metrics, nights: month.nights, asOf: now, calendar: utcCalendar)

        for (earlier, later) in zip(findings, findings.dropFirst()) {
            #expect(FindingRanker.score(earlier) >= FindingRanker.score(later))
        }
    }

    @Test func theSameCacheAlwaysRanksTheSameWay() {
        // records arrive from SwiftData in no promised order, and the detectors
        // walk a dictionary on the way out; the list the user reads each
        // morning still has to be the same list
        let month = syntheticMonth
        let asStored = InsightEngine.dailyFindings(
            metrics: month.metrics, nights: month.nights, asOf: now, calendar: utcCalendar)
        let reversed = InsightEngine.dailyFindings(
            metrics: month.metrics.reversed(), nights: month.nights.reversed(),
            asOf: now, calendar: utcCalendar)

        #expect(asStored.map(\.type) == reversed.map(\.type))
        #expect(asStored.map(\.metric) == reversed.map(\.metric))
        #expect(asStored.map(\.magnitude) == reversed.map(\.magnitude))
    }

    @Test func anEmptyCacheSaysNothing() {
        let findings = InsightEngine.dailyFindings(
            metrics: [], nights: [], asOf: now, calendar: utcCalendar)
        #expect(findings.isEmpty)
    }
}
