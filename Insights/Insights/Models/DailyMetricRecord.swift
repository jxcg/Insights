import Foundation
import SwiftData

/// One cached number: one metric, on one day. Resting heart rate last Tuesday.
/// The cache is thousands of these, and everything the engine says traces back
/// to them.
@Model
final class DailyMetricRecord {
    var date: Date
    var metricKind: String
    var value: Double
    var unit: String

    init(date: Date, metricKind: String, value: Double, unit: String) {
        self.date = date
        self.metricKind = metricKind
        self.value = value
        self.unit = unit
    }
}
