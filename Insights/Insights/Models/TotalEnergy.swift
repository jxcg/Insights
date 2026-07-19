import Foundation

/// Derives total daily energy from the two cached series: active + resting.
/// HealthKit has no total-energy type, and storing the sum would be a cache
/// of a cache that can drift — so it's computed wherever it's displayed.
enum TotalEnergy {
    struct DayTotal: Identifiable {
        let day: Date
        let kilocalories: Double
        var id: Date { day }
    }

    /// Resting energy below this on a day means the watch was mostly off and
    /// the day under-recorded, so the total is omitted rather than shown
    /// misleadingly low. A genuine full day of resting burn sits well above
    /// 1000 kcal; a few watch-on hours record only a few hundred.
    static let minimumRestingKilocalories = 500.0

    /// Joins the two series by day, oldest first. A day only gets a total
    /// when its resting number is plausible; missing active on a plausible
    /// day counts as zero movement, not missing data.
    static func dailyTotals(active: [DailyMetricRecord], basal: [DailyMetricRecord]) -> [DayTotal] {
        let activeByDay = Dictionary(active.map { ($0.date, $0.value) }) { first, _ in first }
        return basal
            .filter { $0.value >= minimumRestingKilocalories }
            .map { DayTotal(day: $0.date, kilocalories: $0.value + (activeByDay[$0.date] ?? 0)) }
            .sorted { $0.day < $1.day }
    }
}
