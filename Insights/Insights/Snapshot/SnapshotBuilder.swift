import Foundation

/// Turns the cache, the readiness score and the day's narrated findings into
/// a `DailySnapshot`.
///
/// Pure: same inputs, same snapshot, no Health access and no model calls.
/// Narration happens later and only replaces `insights`, so the screen builds
/// a snapshot once, from templates, and never rebuilds it for wording.
enum SnapshotBuilder {
    // a sync older than this shows the stale indicator. Twelve hours means a
    // morning open after an evening sync still reads fresh.
    static let freshSyncInterval: TimeInterval = 12 * 3600

    // the common default; there is no goal in Apple Health to read instead
    static let stepGoal = 10_000.0

    static let sparklineDays = 7

    static func build(
        history: HealthHistory,
        digest: DailyDigest,
        lastSynced: Date?,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> DailySnapshot {
        let provisional = provisionalData(history: history, asOf: now, calendar: calendar)
        return DailySnapshot(
            readiness: ReadinessCalculator.readiness(history: history, asOf: now, calendar: calendar),
            tiles: tiles(history: history, provisional: provisional, asOf: now, calendar: calendar),
            insights: digest.insights.map(insight),
            weekReadiness: ReadinessCalculator.week(history: history, asOf: now, calendar: calendar),
            lastSynced: lastSynced,
            syncFresh: isFresh(lastSynced, asOf: now),
            provisional: provisional,
            hasAnyData: !history.isEmpty)
    }

    static func isFresh(_ lastSynced: Date?, asOf now: Date) -> Bool {
        guard let lastSynced else { return false }
        return now.timeIntervalSince(lastSynced) <= freshSyncInterval
    }

    // MARK: Insights

    static func insight(from narrated: NarratedInsight) -> Insight {
        Insight(
            sentence: narrated.sentence,
            evidence: evidence(for: narrated.finding),
            symbol: symbol(for: narrated.finding),
            tone: narrated.finding.tone)
    }

    /// The numbers behind a finding, kept short: "62 bpm · usually 54 bpm".
    static func evidence(for finding: Finding) -> String {
        let metric = finding.metric
        switch finding.type {
        case .anomaly:
            return "\(metric.formattedWithUnit(finding.currentValue)) · usually "
                + metric.formattedWithUnit(finding.baselineValue)
        case .trend:
            return "\(finding.windowDays)-day trend · now \(metric.formattedWithUnit(finding.currentValue))"
        case .correlation:
            return "Pattern across the past \(finding.windowDays) days"
        }
    }

    /// One SF Symbol per row. A one-day reading shows its metric; a trend
    /// shows its direction; a relationship shows a link.
    static func symbol(for finding: Finding) -> String {
        switch finding.type {
        case .anomaly:
            return symbol(for: finding.metric)
        case .trend:
            return finding.direction == .falling
                ? "chart.line.downtrend.xyaxis"
                : "chart.line.uptrend.xyaxis"
        case .correlation:
            return "link"
        }
    }

    static func symbol(for metric: AnalyticMetric) -> String {
        switch metric {
        case .quantity(let kind):
            switch kind {
            case .heartRate, .restingHeartRate: return "heart"
            case .hrv: return "waveform.path.ecg"
            case .steps: return "figure.walk"
            case .activeEnergy, .basalEnergy: return "flame"
            case .vo2Max: return "lungs"
            case .respiratoryRate: return "wind"
            case .wristTemperature: return "thermometer.medium"
            }
        case .sleepDuration: return "bed.double"
        case .deepSleepDuration, .remSleepDuration: return "moon.zzz"
        }
    }

    // MARK: Provisional data

    static func provisionalData(
        history: HealthHistory,
        asOf now: Date,
        calendar: Calendar
    ) -> ProvisionalData {
        guard let lastNight = history.night(wakingOn: calendar.startOfDay(for: now), calendar: calendar),
              now.timeIntervalSince(lastNight.end) < SleepNightAggregator.sessionGap else {
            return .settled
        }
        return ProvisionalData(lastNightStillSettling: true, lastNightHoursSoFar: lastNight.asleep / 3600)
    }

    // MARK: Tiles

    static func tiles(
        history: HealthHistory,
        provisional: ProvisionalData,
        asOf now: Date,
        calendar: Calendar
    ) -> [MetricTile] {
        let seriesByMetric = history.series(asOf: now)

        // the same rule the engine uses for "unusual", so a tile and an
        // insight never disagree about whether something is off
        let outOfRange = Set(
            AnomalyDetector.detect(seriesByMetric, asOf: now, calendar: calendar)
                .filter { $0.tone == .cautionary }
                .map(\.metric))

        return MetricTile.Metric.allCases.map { tileMetric in
            let metric = analyticMetric(for: tileMetric)
            let series = seriesByMetric[metric] ?? []
            let judgedDay = metric.latestCompleteDay(asOf: now, calendar: calendar)
            let latest = value(on: judgedDay, in: series, calendar: calendar)
            let usual = usualValue(in: series, before: judgedDay, calendar: calendar)

            switch tileMetric {
            case .sleep:
                return sleepTile(
                    latest: latest, usual: usual, history: history, provisional: provisional,
                    attention: outOfRange.contains(metric), today: judgedDay, calendar: calendar)
            case .hrv, .restingHeartRate:
                return MetricTile(
                    metric: tileMetric,
                    value: latest.map { String(Int($0.rounded())) },
                    unit: metric.unitLabel,
                    caption: usual.map { "usually \(Int($0.rounded()))" },
                    visual: sparkline(series, endingOn: judgedDay, calendar: calendar),
                    needsAttention: outOfRange.contains(metric))
            case .steps:
                return MetricTile(
                    metric: tileMetric,
                    value: latest.map { Int($0.rounded()).formatted() },
                    unit: "steps",
                    caption: "goal \(Int(stepGoal).formatted())",
                    visual: progressVisual(latest),
                    needsAttention: outOfRange.contains(metric))
            }
        }
    }

    static func analyticMetric(for tile: MetricTile.Metric) -> AnalyticMetric {
        switch tile {
        case .sleep: .sleepDuration
        case .hrv: .quantity(.hrv)
        case .restingHeartRate: .quantity(.restingHeartRate)
        case .steps: .quantity(.steps)
        }
    }

    // an unsettled night has no final figure yet, so the tile shows the hours
    // so far and says it is still syncing
    private static func sleepTile(
        latest: Double?,
        usual: Double?,
        history: HealthHistory,
        provisional: ProvisionalData,
        attention: Bool,
        today: Date,
        calendar: Calendar
    ) -> MetricTile {
        let shownHours = latest ?? provisional.lastNightHoursSoFar
        let caption: String?
        if latest == nil, provisional.lastNightStillSettling {
            caption = "still syncing"
        } else {
            caption = usual.map { "usually \(oneDecimal($0)) h" }
        }

        var visual = MetricTile.Visual.empty
        if let night = history.night(wakingOn: today, calendar: calendar),
           night.asleep > 0, let deep = night.deep, let rem = night.rem {
            let deepShare = deep / night.asleep
            let remShare = rem / night.asleep
            visual = .sleepStages(
                deep: deepShare, rem: remShare, core: max(0, 1 - deepShare - remShare))
        }

        return MetricTile(
            metric: .sleep,
            value: shownHours.map(oneDecimal),
            unit: "h",
            caption: caption,
            visual: visual,
            needsAttention: attention)
    }

    // locale-aware like the steps figure, so the grid never mixes "7.2" with
    // "8.640"
    private static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private static func value(on day: Date, in series: [DatedValue], calendar: Calendar) -> Double? {
        series.first(where: { calendar.startOfDay(for: $0.day) == day })?.value
    }

    // the same 30-day normal the anomaly detector measures against
    private static func usualValue(in series: [DatedValue], before day: Date, calendar: Calendar) -> Double? {
        guard let end = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
        return MetricBaseline.compute(
            over: series, windowDays: AnomalyDetector.baselineWindowDays,
            endingOn: end, calendar: calendar)?.mean
    }

    private static func sparkline(_ series: [DatedValue], endingOn end: Date, calendar: Calendar) -> MetricTile.Visual {
        guard let start = calendar.date(byAdding: .day, value: -(sparklineDays - 1), to: end) else {
            return .empty
        }
        let recent = series
            .filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= start && day <= end
            }
            .map(\.value)
        // one point is not a line
        return recent.count >= 2 ? .sparkline(recent) : .empty
    }

    private static func progressVisual(_ steps: Double?) -> MetricTile.Visual {
        guard let steps else { return .empty }
        return .progress(steps / stepGoal)
    }
}
