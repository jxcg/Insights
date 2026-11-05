import Foundation
import Testing
@testable import Insights

// midday 18 Jul: quantities judged on 17 Jul, last night ends 18 Jul
private let now = day(2026, 7, 18).addingTimeInterval(12 * 3600)

private func finding(
    _ type: Finding.FindingType,
    metric: AnalyticMetric = .quantity(.restingHeartRate),
    direction: Finding.Direction = .rising,
    current: Double = 62,
    baseline: Double = 54,
    windowDays: Int = 30
) -> Finding {
    Finding(
        type: type, metric: metric, drivingMetric: nil, magnitude: 2, currentValue: current,
        baselineValue: baseline, windowDays: windowDays, confidence: 1, direction: direction,
        tone: .cautionary, meaning: "m", plainStatement: "p")
}

// 30 days of one metric ending yesterday, steady at `usual` with a small
// wobble, then `yesterday` on 17 Jul
private func month(_ kind: MetricKind, usual: Double, yesterday: Double) -> [DailyMetricRecord] {
    var records = (1...30).map { daysBack in
        DailyMetricRecord(
            date: utcCalendar.date(byAdding: .day, value: -daysBack, to: day(2026, 7, 17))!,
            metricKind: kind.rawValue,
            value: usual + (daysBack.isMultiple(of: 2) ? 1 : -1),
            unit: kind.unitLabel)
    }
    records.append(DailyMetricRecord(
        date: day(2026, 7, 17), metricKind: kind.rawValue, value: yesterday, unit: kind.unitLabel))
    return records
}

private func night(wakeDay: Date, hours: Double, endingAt end: Date? = nil, deep: Double? = nil, rem: Double? = nil) -> SleepNightRecord {
    let bedtime = wakeDay.addingTimeInterval(-3600)
    return SleepNightRecord(night: SleepNight(
        wakeDay: wakeDay, start: bedtime,
        end: end ?? bedtime.addingTimeInterval(hours * 3600),
        asleep: hours * 3600, deep: deep.map { $0 * 3600 }, rem: rem.map { $0 * 3600 }))
}

private func build(
    metrics: [DailyMetricRecord] = [],
    nights: [SleepNightRecord] = [],
    lastSynced: Date? = now
) -> DailySnapshot {
    SnapshotBuilder.build(
        history: HealthHistory(metrics: metrics, nights: nights),
        digest: DailyDigest(insights: []),
        lastSynced: lastSynced, asOf: now, calendar: utcCalendar)
}

@Suite struct SnapshotInsightTests {

    @Test func anAnomalyQuotesTodayAgainstUsual() {
        #expect(SnapshotBuilder.evidence(for: finding(.anomaly)) == "62 bpm · usually 54 bpm")
    }

    @Test func aTrendQuotesItsWindowAndLatestValue() {
        #expect(SnapshotBuilder.evidence(for: finding(.trend, current: 58, windowDays: 21))
            == "21-day trend · now 58 bpm")
    }

    @Test func aCorrelationQuotesItsWindow() {
        #expect(SnapshotBuilder.evidence(for: finding(.correlation, windowDays: 90))
            == "Pattern across the past 90 days")
    }

    @Test func symbolsFollowTheKindOfFinding() {
        #expect(SnapshotBuilder.symbol(for: finding(.anomaly)) == "heart")
        #expect(SnapshotBuilder.symbol(for: finding(.anomaly, metric: .sleepDuration)) == "bed.double")
        #expect(SnapshotBuilder.symbol(for: finding(.trend, direction: .rising)) == "chart.line.uptrend.xyaxis")
        #expect(SnapshotBuilder.symbol(for: finding(.trend, direction: .falling)) == "chart.line.downtrend.xyaxis")
        #expect(SnapshotBuilder.symbol(for: finding(.correlation)) == "link")
    }

    @Test func narratedSentencesCarryThrough() {
        let narrated = NarratedInsight(finding: finding(.anomaly), sentence: "Your resting heart rate was high.", source: .model)
        let insight = SnapshotBuilder.insight(from: narrated)

        #expect(insight.sentence == "Your resting heart rate was high.")
        #expect(insight.tone == .cautionary)
    }
}

@Suite struct SnapshotStateTests {

    @Test func anEmptyCacheSaysSo() {
        let snapshot = build(lastSynced: nil)

        #expect(snapshot.hasAnyData == false)
        #expect(snapshot.readiness == nil)
        #expect(snapshot.recoveryState == .recovered)
        #expect(snapshot.tiles.allSatisfy { $0.value == nil })
    }

    @Test func freshnessEndsAfterTwelveHours() {
        #expect(SnapshotBuilder.isFresh(now.addingTimeInterval(-12 * 3600), asOf: now))
        #expect(!SnapshotBuilder.isFresh(now.addingTimeInterval(-12 * 3600 - 1), asOf: now))
        #expect(!SnapshotBuilder.isFresh(nil, asOf: now))
    }

    @Test func aNightEndedHalfAnHourAgoIsProvisional() {
        let settling = night(wakeDay: day(2026, 7, 18), hours: 6, endingAt: now.addingTimeInterval(-1800))
        let snapshot = build(nights: [settling])

        #expect(snapshot.provisional.lastNightStillSettling)
        #expect(snapshot.provisional.lastNightHoursSoFar == 6)

        // the tile shows the hours so far and says why they are not final
        let sleepTile = snapshot.tiles.first { $0.metric == .sleep }
        #expect(sleepTile?.value == "6.0")
        #expect(sleepTile?.caption == "still syncing")
    }

    @Test func aSettledNightIsNotProvisional() {
        let snapshot = build(nights: [night(wakeDay: day(2026, 7, 18), hours: 7)])
        #expect(!snapshot.provisional.lastNightStillSettling)
    }
}

@Suite struct SnapshotTileTests {

    @Test func theGridIsSleepHRVRestingHeartRateSteps() {
        #expect(build().tiles.map(\.metric) == [.sleep, .hrv, .restingHeartRate, .steps])
    }

    @Test func stepsShowProgressTowardTheGoal() {
        let snapshot = build(metrics: month(.steps, usual: 8600, yesterday: 8640))
        let steps = snapshot.tiles.first { $0.metric == .steps }

        guard case .progress(let share) = steps?.visual else {
            Issue.record("steps tile should draw progress")
            return
        }
        // 8,640 of 10,000
        #expect(abs(share - 0.864) < 0.000001)
    }

    @Test func aRestingHeartRateSpikeGetsAttention() {
        // usual 54 ± 1, yesterday 62: far past 1.5 SD, and rising resting heart
        // rate is the unwelcome direction
        let snapshot = build(metrics: month(.restingHeartRate, usual: 54, yesterday: 62))
        let resting = snapshot.tiles.first { $0.metric == .restingHeartRate }

        #expect(resting?.value == "62")
        #expect(resting?.caption == "usually 54")
        #expect(resting?.needsAttention == true)
    }

    @Test func anOrdinaryDayGetsNoAttention() {
        let snapshot = build(metrics: month(.restingHeartRate, usual: 54, yesterday: 54))
        #expect(snapshot.tiles.allSatisfy { !$0.needsAttention })
    }

    @Test func aWelcomeSpikeGetsNoAttention() {
        // HRV far above usual is good news, not a warning
        let snapshot = build(metrics: month(.hrv, usual: 55, yesterday: 75))
        let hrv = snapshot.tiles.first { $0.metric == .hrv }
        #expect(hrv?.needsAttention == false)
    }

    @Test func recentDaysDrawASparkline() {
        let snapshot = build(metrics: month(.hrv, usual: 55, yesterday: 58))
        let hrv = snapshot.tiles.first { $0.metric == .hrv }

        guard case .sparkline(let points) = hrv?.visual else {
            Issue.record("HRV tile should draw a sparkline")
            return
        }
        // the seven days ending yesterday, oldest first
        #expect(points.count == SnapshotBuilder.sparklineDays)
        #expect(points.last == 58)
    }

    @Test func lastNightsStagesDrawAsShares() {
        // 8 h night: 1.6 h deep is 0.2, 2 h REM is 0.25, the rest core 0.55
        let snapshot = build(nights: [night(wakeDay: day(2026, 7, 18), hours: 8, deep: 1.6, rem: 2)])
        let sleep = snapshot.tiles.first { $0.metric == .sleep }

        guard case .sleepStages(let deep, let rem, let core) = sleep?.visual else {
            Issue.record("sleep tile should draw stages")
            return
        }
        #expect(abs(deep - 0.2) < 0.000001)
        #expect(abs(rem - 0.25) < 0.000001)
        #expect(abs(core - 0.55) < 0.000001)
    }
}
