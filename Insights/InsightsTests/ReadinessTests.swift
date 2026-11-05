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

// sample standard deviation, written out independently of MetricBaseline
private func sampleSD(_ values: [Double]) -> Double {
    let mean = values.reduce(0, +) / Double(values.count)
    let squares = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
    return (squares / Double(values.count - 1)).squareRoot()
}

/// A month of steady history, then one judged morning.
///
/// "now" is midday 18 Jul. Quantities are judged on 17 Jul against the 30
/// days 17 Jun to 16 Jul; sleep is judged on the night ending 18 Jul against
/// nights ending 18 Jun to 17 Jul. History alternates between two values, so
/// its mean is their midpoint.
private struct Month {
    static let now = day(2026, 7, 18).addingTimeInterval(12 * 3600)

    static let hrvHistory = alternating(52, 58)          // mean 55 ms
    static let restingHistory = alternating(53, 57)      // mean 55 bpm
    static let sleepHistory = alternating(6.8, 7.6)      // mean 7.2 h

    static func alternating(_ low: Double, _ high: Double) -> [Double] {
        (0..<30).map { $0.isMultiple(of: 2) ? low : high }
    }

    // `sd` is how many standard deviations of history each judged value sits
    // from its mean, in the direction that is worse for recovery
    static func records(
        worseBy sd: Double = 0,
        include: Set<String> = ["hrv", "resting", "sleep"],
        historyDays: Int = 30
    ) -> (metrics: [DailyMetricRecord], nights: [SleepNightRecord]) {
        var metrics: [DailyMetricRecord] = []
        var nights: [SleepNightRecord] = []
        let judgedQuantityDay = day(2026, 7, 17)

        func quantity(_ kind: MetricKind, history: [Double], judged: Double) {
            for (offset, value) in history.suffix(historyDays).reversed().enumerated() {
                let date = utcCalendar.date(byAdding: .day, value: -(offset + 1), to: judgedQuantityDay)!
                metrics.append(DailyMetricRecord(date: date, metricKind: kind.rawValue, value: value, unit: kind.unitLabel))
            }
            metrics.append(DailyMetricRecord(
                date: judgedQuantityDay, metricKind: kind.rawValue, value: judged, unit: kind.unitLabel))
        }

        func night(wakeDay: Date, hours: Double) -> SleepNightRecord {
            let bedtime = wakeDay.addingTimeInterval(-3600)
            return SleepNightRecord(night: SleepNight(
                wakeDay: wakeDay, start: bedtime, end: bedtime.addingTimeInterval(hours * 3600),
                asleep: hours * 3600, deep: nil, rem: nil))
        }

        if include.contains("hrv") {
            quantity(.hrv, history: hrvHistory, judged: 55 - sd * sampleSD(hrvHistory))
        }
        if include.contains("resting") {
            quantity(.restingHeartRate, history: restingHistory, judged: 55 + sd * sampleSD(restingHistory))
        }
        if include.contains("sleep") {
            let judgedNight = day(2026, 7, 18)
            for (offset, hours) in sleepHistory.suffix(historyDays).reversed().enumerated() {
                nights.append(night(
                    wakeDay: utcCalendar.date(byAdding: .day, value: -(offset + 1), to: judgedNight)!,
                    hours: hours))
            }
            nights.append(night(wakeDay: judgedNight, hours: 7.2 - sd * sampleSD(sleepHistory)))
        }
        return (metrics, nights)
    }

    static func readiness(worseBy sd: Double = 0, include: Set<String> = ["hrv", "resting", "sleep"], historyDays: Int = 30) -> Readiness? {
        let month = records(worseBy: sd, include: include, historyDays: historyDays)
        return ReadinessCalculator.readiness(
            metrics: month.metrics, nights: month.nights, asOf: now, calendar: utcCalendar)
    }
}

@Suite struct ReadinessTests {

    @Test func anOrdinaryMorningScoresSeventy() {
        // every input exactly at its own mean: z = 0 everywhere, 70 + 15 × 0
        #expect(Month.readiness()?.score == 70)
    }

    @Test func theLowRecoveryLineIsOneStandardDeviationBelowNormal() {
        // 70 − 15 = 55
        #expect(ReadinessCalculator.lowRecoveryThreshold == 55)
    }

    @Test func oneInputOneStandardDeviationWorseLandsOnTheLine() {
        // HRV alone at z = −1: composite = 0.4 × −1 ÷ √0.16 = −1, so
        // 70 + 15 × −1 = 55. The line itself still counts as recovered.
        let readiness = Month.readiness(worseBy: 1, include: ["hrv"])
        #expect(readiness?.score == 55)
        #expect(readiness?.state == .recovered)
    }

    @Test func justPastTheLineIsLowRecovery() {
        // HRV alone at z = −1.2: 70 + 15 × −1.2 = 52
        let readiness = Month.readiness(worseBy: 1.2, include: ["hrv"])
        #expect(readiness?.score == 52)
        #expect(readiness?.state == .lowRecovery)
    }

    @Test func allThreeWorseAtOnceIsWellBelowTheLine() {
        // z = −1 on every input: Σ w × z = −1, √(0.16 + 0.09 + 0.09) = √0.34,
        // composite −1 ÷ 0.5831 = −1.715, score 70 − 25.7 = 44.3, shown 44.
        // Three inputs all a full SD off at once is rarer than one, so it
        // reads lower.
        let readiness = Month.readiness(worseBy: 1)
        #expect(readiness?.score == 44)
        #expect(readiness?.state == .lowRecovery)
    }

    @Test func aBetterThanUsualMorningScoresAboveSeventy() {
        // z = +1 everywhere: composite +1.715, 70 + 25.7 = 95.7, shown 96
        #expect(Month.readiness(worseBy: -1)?.score == 96)
    }

    @Test func lowerRestingHeartRateCountsAsBetter() {
        // only resting heart rate, 1 SD below its mean: that is good news, 85
        #expect(Month.readiness(worseBy: -1, include: ["resting"])?.score == 85)
    }

    @Test func aMissingInputIsLeftOutNotCountedAsZero() {
        // HRV and sleep both 1 SD worse, no resting heart rate data:
        // Σ w × z = −0.7, √(0.16 + 0.09) = 0.5, composite −1.4, 70 − 21 = 49.
        let readiness = Month.readiness(worseBy: 1, include: ["hrv", "sleep"])
        #expect(readiness?.score == 49)
        #expect(readiness?.inputsUsed.count == 2)
    }

    @Test func oneFreakReadingIsCapped() {
        // 10 SD worse would be 70 − 150; the cap holds it to 3 SD, 70 − 45 = 25
        #expect(Month.readiness(worseBy: 10, include: ["hrv"])?.score == 25)
    }

    @Test func theScoreNeverLeavesZeroToHundred() {
        // z = +4 everywhere, capped to +3: composite 3 ÷ 0.5831 = 5.14,
        // 70 + 77 = 147, held to 100. (At +4 SD last night is 8.8 h, ending
        // 07:50, well settled by midday, so all three inputs count.)
        let readiness = Month.readiness(worseBy: -4)
        #expect(readiness?.score == 100)
        #expect(readiness?.inputsUsed.count == 3)
    }

    @Test func tooLittleHistoryGivesNoScore() {
        // six days of history is under the seven-day minimum
        #expect(Month.readiness(historyDays: 6) == nil)
    }

    @Test func noDataGivesNoScore() {
        let readiness = ReadinessCalculator.readiness(
            metrics: [], nights: [], asOf: Month.now, calendar: utcCalendar)
        #expect(readiness == nil)
    }

    @Test func deltaIsTodayMinusYesterdayMorning() {
        // today: all three 1 SD worse, 44 (see above).
        // yesterday morning judged 16 Jul's HRV 58 and resting 57, and the
        // 7.6 h night ending 17 Jul, each against the 29 days before: every
        // input z = +1.017 in its own direction, so HRV +1.017, resting
        // −1.017, sleep +1.017. Σ w × z = 0.4068, ÷ 0.5831 = 0.698,
        // 70 + 10.5 = 80.5, shown 80. Delta 44 − 80 = −36.
        #expect(Month.readiness(worseBy: 1)?.delta == -36)
    }

    @Test func theWeekIsSevenMorningsEndingToday() {
        let month = Month.records()
        let week = ReadinessCalculator.week(
            metrics: month.metrics, nights: month.nights, asOf: Month.now, calendar: utcCalendar)

        #expect(week.count == 7)
        #expect(week.last?.day == day(2026, 7, 18))
        #expect(week.first?.day == day(2026, 7, 12))
        #expect(week.last?.score == 70)
    }

    @Test(arguments: [false, true])
    func pastMorningsDoNotFollowTodaysClock(includeTodaysSleep: Bool) throws {
        let month = Month.records(worseBy: 1)
        let today = day(2026, 7, 18)
        let nights = month.nights.filter { includeTodaysSleep || $0.wakeDay < today }
        let early = today.addingTimeInterval(6.5 * 3600)

        let earlyWeek = ReadinessCalculator.week(
            metrics: month.metrics, nights: nights, asOf: early, calendar: utcCalendar)
        let noonWeek = ReadinessCalculator.week(
            metrics: month.metrics, nights: nights, asOf: Month.now, calendar: utcCalendar)
        #expect(earlyWeek.map(\.day) == noonWeek.map(\.day))
        #expect(earlyWeek.dropLast().allSatisfy { $0.score != nil })
        #expect(earlyWeek.dropLast().map(\.score) == noonWeek.dropLast().map(\.score))

        let earlyReadiness = try #require(ReadinessCalculator.readiness(
            metrics: month.metrics, nights: nights, asOf: early, calendar: utcCalendar))
        let noonReadiness = try #require(ReadinessCalculator.readiness(
            metrics: month.metrics, nights: nights, asOf: Month.now, calendar: utcCalendar))
        let earlyDelta = try #require(earlyReadiness.delta)
        let noonDelta = try #require(noonReadiness.delta)

        // Yesterday scores 80 with its settled sleep, regardless of the clock.
        #expect(earlyReadiness.score - earlyDelta == 80)
        #expect(noonReadiness.score - noonDelta == 80)
        #expect(earlyWeek[5].score == 80)
        #expect(earlyWeek.last?.score == earlyReadiness.score)
        #expect(noonWeek.last?.score == noonReadiness.score)

        // Today's unsettled sleep must still sit out at 06:30. Delta may move
        // only by today's change, not by yesterday's sleep dropping in or out.
        #expect(earlyReadiness.score == 49)
        #expect(!earlyReadiness.inputsUsed.contains(.sleepDuration))
        #expect(noonReadiness.score == (includeTodaysSleep ? 44 : 49))
        #expect(noonReadiness.inputsUsed.contains(.sleepDuration) == includeTodaysSleep)
        #expect(noonDelta - earlyDelta == noonReadiness.score - earlyReadiness.score)
        print("CI: readiness \"historical\" = \(earlyReadiness.score - earlyDelta), today = \(earlyReadiness.score) -> \(noonReadiness.score)")
    }

    @Test func historicalLateWakeUpsUseTheirLocalDayAcrossDST() {
        var calendar = utcCalendar
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        // Yesterday was the 25-hour day when British Summer Time ended.
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let nights = (1...40).map { offset in
            let wakeDay = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: wakeDay)!
            let asleep = (offset.isMultiple(of: 2) ? 7.0 : 9.0) * 3600
            return SleepNightRecord(night: SleepNight(
                wakeDay: wakeDay, start: end.addingTimeInterval(-asleep), end: end,
                asleep: asleep, deep: nil, rem: nil))
        }
        let earlyWeek = ReadinessCalculator.week(
            metrics: [], nights: nights, asOf: today.addingTimeInterval(6.5 * 3600), calendar: calendar)
        let noonWeek = ReadinessCalculator.week(
            metrics: [], nights: nights, asOf: today.addingTimeInterval(12 * 3600), calendar: calendar)

        #expect(earlyWeek.count == 7)
        #expect(Set(earlyWeek.map(\.day)).count == 7)
        #expect(earlyWeek.first?.day == calendar.date(byAdding: .day, value: -6, to: today))
        #expect(earlyWeek.last?.day == today)
        #expect(earlyWeek.dropLast().allSatisfy { $0.score != nil })
        #expect(earlyWeek.map(\.score) == noonWeek.map(\.score))
        // Yesterday's nine hours against a mean of eight, SD sqrt(30/29).
        #expect(earlyWeek[5].score == 85)
        #expect(earlyWeek.last?.score == nil)
    }
}
