import Charts
import SwiftUI
import SwiftData

/// One metric's cached days, raw, newest first, so numbers can be checked line
/// by line against the Health app.
///
/// When the engine says something surprising, this is where you find out
/// whether the data or the maths was at fault.
struct MetricDetailView: View {
    let kind: MetricKind

    @Query private var records: [DailyMetricRecord]

    init(kind: MetricKind) {
        self.kind = kind
        let key = kind.rawValue
        _records = Query(
            filter: #Predicate<DailyMetricRecord> { $0.metricKind == key },
            sort: \DailyMetricRecord.date,
            order: .reverse
        )
    }

    var body: some View {
        List {
            if records.isEmpty {
                Text("No cached days for this metric.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    chart
                }
                ForEach(records) { record in
                    HStack {
                        Text(record.date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text("\(formattedValue(record.value)) \(record.unit)")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A shape check over the same days the table lists. Bars for metrics that
    /// add up, a line for ones that average.
    private var chart: some View {
        Chart(records) { record in
            if kind.aggregation == .sum {
                BarMark(
                    x: .value("Day", record.date, unit: .day),
                    y: .value(kind.displayName, record.value)
                )
            } else {
                LineMark(
                    x: .value("Day", record.date, unit: .day),
                    y: .value(kind.displayName, record.value)
                )
            }
        }
        // averaged metrics sit nowhere near zero, and forcing it in would flatten
        // wrist temperature into a straight line
        .chartYScale(domain: .automatic(includesZero: kind.aggregation == .sum))
        .frame(height: 160)
    }

    /// Counted metrics read as whole numbers; measured ones keep a decimal.
    private func formattedValue(_ value: Double) -> String {
        kind.aggregation == .sum
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

#Preview {
    NavigationStack {
        MetricDetailView(kind: .heartRate)
    }
    .modelContainer(for: [DailyMetricRecord.self], inMemory: true)
}
