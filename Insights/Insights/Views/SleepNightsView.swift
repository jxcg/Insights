import Charts
import SwiftUI
import SwiftData

/// Cached sleep nights laid out raw, newest first, for checking line by line
/// against the Health app's own sleep history.
struct SleepNightsView: View {
    @Query(sort: \SleepNightRecord.wakeDay, order: .reverse) private var nights: [SleepNightRecord]

    var body: some View {
        List {
            if nights.isEmpty {
                Text("No cached nights.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    chart
                }
                ForEach(nights) { record in
                    row(for: record.night)
                }
            }
        }
        .navigationTitle("Sleep nights")
        .navigationBarTitleDisplayMode(.inline)
    }

    // a shape check over the same nights the table lists, one bar per night
    private var chart: some View {
        Chart(nights) { record in
            BarMark(
                x: .value("Night", record.wakeDay, unit: .day),
                y: .value("Hours asleep", record.night.asleepHours)
            )
        }
        .frame(height: 160)
    }

    // one night: the morning it ended, hours asleep, and the stage split when
    // that was recorded
    private func row(for night: SleepNight) -> some View {
        HStack {
            Text(night.wakeDay.formatted(date: .abbreviated, time: .omitted))
            Spacer()
            Text(details(for: night))
                .monospacedDigit()
        }
        .font(.callout)
    }

    // stages only show up when the night actually recorded them
    private func details(for night: SleepNight) -> String {
        var text = String(format: "%.1fh", night.asleepHours)
        if let deep = night.deepPercent, let rem = night.remPercent {
            text += String(format: " · deep %.0f%% · rem %.0f%%", deep, rem)
        }
        return text
    }
}

#Preview {
    NavigationStack {
        SleepNightsView()
    }
    .modelContainer(for: [SleepNightRecord.self], inMemory: true)
}
