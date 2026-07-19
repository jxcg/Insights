import Charts
import SwiftUI
import SwiftData

/// Derived total energy (active + resting) per day, newest first
/// nothing on this screen is stored, every row is computed from the
/// two cached energy series so it can be checked against the Health app
struct TotalEnergyView: View {
    @Query private var energyRecords: [DailyMetricRecord]

    init() {
        let energyKeys = [MetricKind.activeEnergy.rawValue, MetricKind.basalEnergy.rawValue]
        _energyRecords = Query(
            filter: #Predicate<DailyMetricRecord> { energyKeys.contains($0.metricKind) })
    }

    /// The join itself, oldest first for the chart
    private var totals: [TotalEnergy.DayTotal] {
        TotalEnergy.dailyTotals(
            active: energyRecords.filter { $0.metricKind == MetricKind.activeEnergy.rawValue },
            basal: energyRecords.filter { $0.metricKind == MetricKind.basalEnergy.rawValue })
    }

    var body: some View {
        List {
            if totals.isEmpty {
                Text("No days with a full resting-energy record yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    chart
                } footer: {
                    Text("Days where the watch under-recorded resting energy are left out rather than shown low.")
                }
                ForEach(totals.reversed()) { total in
                    HStack {
                        Text(total.day.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text("\(String(format: "%.0f", total.kilocalories)) kcal")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .navigationTitle("Total energy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chart: some View {
        Chart(totals) { total in
            BarMark(
                x: .value("Day", total.day, unit: .day),
                y: .value("Total energy", total.kilocalories)
            )
        }
        .frame(height: 160)
    }
}

#Preview {
    NavigationStack {
        TotalEnergyView()
    }
    .modelContainer(for: [DailyMetricRecord.self], inMemory: true)
}
