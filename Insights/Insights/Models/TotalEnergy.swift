import Foundation

/// Derives total daily energy from the two cached series: active + resting.
/// HealthKit has no total-energy type, and storing the sum would be a cache
/// of a cache that can drift — so it's computed wherever it's displayed.
enum TotalEnergy {
    struct DayTotal: Identifiable {
        let day: Date
        let kilocalories: Double
        /// False while the day is still in progress, or when its resting
        /// number fell short of a typical day — the total exists but reads
        /// low. Analysis should only ever trust fully recorded days.
        let hasCompleteEnergyRecord: Bool
        var id: Date { day }
    }

    /// HealthKit has no flag saying "the watch was off", so an incomplete
    /// day has to be inferred: resting burn is relatively stable, so a day
    /// recording under this share of the person's median is treated as likely
    /// missing hours of data rather than a meaningful physiological change.
    static let minimumShareOfTypicalResting = 0.8

    /// Joins the two series by day, oldest first, every day flagged rather
    /// than filtered — callers choose whether incomplete days are shown.
    /// Missing active on a day the watch was worn counts as zero movement,
    /// not missing data.
    static func dailyTotals(
        active: [DailyMetricRecord],
        basal: [DailyMetricRecord],
        calendar: Calendar = .current
    ) -> [DayTotal] {
        // get the user's median resting energy over the finished days
        // today is excluded because it is still accumulating
        let finishedDays = basal.filter { !calendar.isDateInToday($0.date) }
        let typicalResting = median(finishedDays.map(\.value))

        // active energy looked up by day when building each total
        var activeByDay: [Date: Double] = [:]
        for activeRecord in active {
            activeByDay[activeRecord.date] = activeRecord.value
        }

        // one total per resting-energy day, flagged complete only when the
        // day has ended AND its resting number holds up against a typical day
        var totals: [DayTotal] = []
        for restingRecord in basal {
            let dayHasEnded = !calendar.isDateInToday(restingRecord.date)

            var restingMeetsTypicalShare = false
            if let typicalResting {
                restingMeetsTypicalShare =
                    restingRecord.value >= typicalResting * minimumShareOfTypicalResting
            }

            let activeKilocalories = activeByDay[restingRecord.date] ?? 0
            totals.append(DayTotal(
                day: restingRecord.date,
                kilocalories: restingRecord.value + activeKilocalories,
                hasCompleteEnergyRecord: dayHasEnded && restingMeetsTypicalShare))
        }

        return totals.sorted { $0.day < $1.day }
    }

    /// Median, not mean: the watch-off outliers being screened out must not
    /// drag down the yardstick they're screened against.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
