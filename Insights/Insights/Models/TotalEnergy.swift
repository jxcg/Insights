import Foundation

/// Total daily energy, worked out on the spot: active plus resting.
///
/// Apple Health has no total-energy type. Storing the sum would be a cache of
/// a cache, which can drift out of step, so it is computed wherever it is
/// shown instead.
enum TotalEnergy {
    struct DayTotal: Identifiable {
        let day: Date
        let kilocalories: Double
        /// False while a day is still running, or when its resting number came
        /// in well under a typical day. The total still exists, it just reads
        /// low. Analysis should only trust fully recorded days.
        let hasCompleteEnergyRecord: Bool
        var id: Date { day }
    }

    /// Apple Health has no flag for "the watch was off", so a gap has to be
    /// inferred. Resting burn is fairly steady day to day, so a day coming in
    /// under this share of the user's own median almost certainly lost hours of
    /// recording rather than the body genuinely doing less.
    static let minimumShareOfTypicalResting = 0.8

    /// Joins the two series by day, oldest first. Every day is flagged rather
    /// than dropped, so callers decide whether to show the incomplete ones.
    /// No active energy on a day the watch was worn means no movement, which is
    /// not the same as missing data.
    static func dailyTotals(
        active: [DailyMetricRecord],
        basal: [DailyMetricRecord],
        calendar: Calendar = .current
    ) -> [DayTotal] {
        // what a typical resting day looks like for this user, today left out
        // because it is still adding to itself
        let finishedDays = basal.filter { !calendar.isDateInToday($0.date) }
        let typicalResting = median(finishedDays.map(\.value))

        var activeByDay: [Date: Double] = [:]
        for activeRecord in active {
            activeByDay[activeRecord.date] = activeRecord.value
        }

        // one total per resting-energy day, counted complete only when the day
        // has ended and its resting number holds up against a typical one
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

    /// Median rather than mean, deliberately: the watch-off days being screened
    /// out must not drag down the yardstick they are screened against.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
