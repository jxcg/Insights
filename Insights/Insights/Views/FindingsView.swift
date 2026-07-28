import SwiftUI
import SwiftData

/// The engine's output read straight off the cache, with the workings shown.
/// It exists to answer the only question thresholds can't be tuned without:
/// does today's top five actually say anything worth hearing?
///
/// This is scaffolding, like the dashboard it hangs off. The designed feed
/// arrives with the Today screen, and the sentences here are the engine's own
/// plain statements — no model has been near them.
struct FindingsView: View {
    @Query private var metricRecords: [DailyMetricRecord]
    @Query private var nightRecords: [SleepNightRecord]

    private var findings: [Finding] {
        InsightEngine.dailyFindings(metrics: metricRecords, nights: nightRecords)
    }

    var body: some View {
        List {
            if findings.isEmpty {
                Text("Nothing stood out today. Sync some history and try again.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(findings.enumerated()), id: \.offset) { position, finding in
                    row(position: position, finding: finding)
                }
            }
        }
        .navigationTitle("Today's findings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One finding as the user would hear it, over the numbers that earned it
    /// its place. The score line is here for tuning and would not survive into
    /// the real feed.
    private func row(position: Int, finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(position + 1).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(finding.plainStatement)
            }
            .font(.callout)

            Text(workings(for: finding))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// Why this finding sits where it does, in the terms the ranker used.
    private func workings(for finding: Finding) -> String {
        let score = String(format: "%.2f", FindingRanker.score(finding))
        let strength = String(format: "%.2f", FindingRanker.strength(of: finding))
        let confidence = String(format: "%.0f", finding.confidence * 100)
        return "\(finding.type.rawValue) · \(finding.tone.rawValue) · score \(score) "
            + "(strength \(strength), confidence \(confidence)%, \(finding.windowDays)d)"
    }
}

#Preview {
    NavigationStack {
        FindingsView()
    }
    .modelContainer(for: [DailyMetricRecord.self, SleepNightRecord.self], inMemory: true)
}
