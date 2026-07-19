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
        let finishedDays = basal.filter { !calendar.isDateInToday($0.date) }
        // get the user's median resting energy over a filter
        let typicalResting = median(finishedDays.map(\.value))
        let activeByDay = Dictionary(active.map { ($0.date, $0.value) }) { first, _ in first }

        return basal
            .map { record in
                let dayHasEnded = !calendar.isDateInToday(record.date)
                let restingMeetsTypicalShare = typicalResting.map {
                    record.value >= $0 * minimumShareOfTypicalResting
                } ?? false
                return DayTotal(
                    day: record.date,
                    kilocalories: record.value + (activeByDay[record.date] ?? 0),
                    hasCompleteEnergyRecord: dayHasEnded && restingMeetsTypicalShare)
            }
            .sorted { $0.day < $1.day }
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
