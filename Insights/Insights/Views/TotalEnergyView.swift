import Charts
import SwiftUI
import SwiftData

/// Derived total energy (active + resting) per day, newest first
/// nothing on this screen is stored, every row is computed from the
/// two cached energy series so it can be checked against the Health app
struct TotalEnergyView: View {
    /// Complete hides in-progress and under-recorded days; all shows them
    /// dimmed, so the exclusion rule itself can be checked against reality
    enum Scope: String, CaseIterable, Identifiable {
        case completeDays = "Complete days"
        case allDays = "All days"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .completeDays

    @Query private var energyRecords: [DailyMetricRecord]

    init() {
        let energyKeys = [MetricKind.activeEnergy.rawValue, MetricKind.basalEnergy.rawValue]
        _energyRecords = Query(
            filter: #Predicate<DailyMetricRecord> { energyKeys.contains($0.metricKind) })
    }

    /// The join itself, every day flagged, oldest first for the chart
    private var totals: [TotalEnergy.DayTotal] {
        TotalEnergy.dailyTotals(
            active: energyRecords.filter { $0.metricKind == MetricKind.activeEnergy.rawValue },
            basal: energyRecords.filter { $0.metricKind == MetricKind.basalEnergy.rawValue })
    }

    private var displayedTotals: [TotalEnergy.DayTotal] {
        scope == .completeDays ? totals.filter(\.hasCompleteEnergyRecord) : totals
    }

    var body: some View {
        List {
            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if displayedTotals.isEmpty {
                Text("No days with a full resting-energy record yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    chart
                } footer: {
                    Text(footerText)
                }
                ForEach(displayedTotals.reversed()) { total in
                    HStack {
                        Text(total.day.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text("\(String(format: "%.0f", total.kilocalories)) kcal")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(total.hasCompleteEnergyRecord ? .primary : .secondary)
                }
            }
        }
        .navigationTitle("Total energy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footerText: String {
        scope == .completeDays
            ? "Today is left out until the day is over, along with completed days recording well under your typical resting burn."
            : "Dimmed days are today or under-recorded ones — their totals read low."
    }

    private var chart: some View {
        Chart(displayedTotals) { total in
            BarMark(
                x: .value("Day", total.day, unit: .day),
                y: .value("Total energy", total.kilocalories)
            )
            .opacity(total.hasCompleteEnergyRecord ? 1 : 0.35)
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
