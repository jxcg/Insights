import Foundation
import SwiftData

/// One cached value for one metric on one day (e.g. resting HR on a given date).
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
