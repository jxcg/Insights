import SwiftUI
import SwiftData

/// Raw table of cached sleep nights, newest first
/// line by line check against the Health app's sleep history
struct SleepNightsView: View {
    @Query(sort: \SleepNightRecord.wakeDay, order: .reverse) private var nights: [SleepNightRecord]

    var body: some View {
        List {
            if nights.isEmpty {
                Text("No cached nights.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nights) { record in
                    row(for: record.night)
                }
            }
        }
        .navigationTitle("Sleep nights")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One night: the morning it ended, hours asleep, stage split when known
    private func row(for night: SleepNight) -> some View {
        HStack {
            Text(night.wakeDay.formatted(date: .abbreviated, time: .omitted))
            Spacer()
            Text(details(for: night))
                .monospacedDigit()
        }
        .font(.callout)
    }

    /// Stages only appear when the night actually carried stage data
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
