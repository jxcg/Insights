import Charts
import SwiftUI
import SwiftData

/// Raw table of one metric's cached daily values, newest first
/// exists so the numbers can be checked line by line against the Health app
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

    /// Shape check over the same days the table lists
    /// bars for summed metrics, a line for averaged ones
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
        // averaged metrics sit far from zero, temperature would plot as a flat line
        .chartYScale(domain: .automatic(includesZero: kind.aggregation == .sum))
        .frame(height: 160)
    }

    /// Summed metrics read as whole numbers, averaged ones keep a decimal
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
