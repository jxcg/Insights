import Foundation

/// Total daily energy, worked out on the spot: active plus resting.
///
/// Apple Health has no total-energy type. Storing the sum would be a cache of
/// a cache, which drifts out of step, so it is computed where it is shown.
enum TotalEnergy {
    struct DayTotal: Identifiable {
        let day: Date
        let kilocalories: Double
        // false while a day is still running, or when its resting number came
        // in well under typical. Total still exists, it just reads low, so
        // analysis should only trust fully recorded days.
        let hasCompleteEnergyRecord: Bool
        var id: Date { day }
    }

    // Apple Health has no "watch was off" flag, so gaps get inferred. Resting
    // burn is steady day to day, so a day under this share of the user's own
    // median almost certainly lost recording hours, rather than the body
    // genuinely doing less.
    static let minimumShareOfTypicalResting = 0.8

    /// Joins the two series by day, oldest first. Days get flagged, not
    /// dropped, so callers decide whether to show incomplete ones.
    ///
    /// No active energy on a worn-watch day means no movement, which is not
    /// the same as missing data.
    static func dailyTotals(
        active: [DailyMetricRecord],
        basal: [DailyMetricRecord],
        calendar: Calendar = .current
    ) -> [DayTotal] {
        // typical resting day for this user. Today left out: still counting up.
        let finishedDays = basal.filter { !calendar.isDateInToday($0.date) }
        let typicalResting = median(finishedDays.map(\.value))

        var activeByDay: [Date: Double] = [:]
        for activeRecord in active {
            activeByDay[activeRecord.date] = activeRecord.value
        }

        // one total per resting-energy day. Complete only when the day has
        // ended and its resting number holds up against typical.
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

    // median, not mean, deliberately: watch-off days being screened out must
    // not drag down the yardstick they are screened against
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
