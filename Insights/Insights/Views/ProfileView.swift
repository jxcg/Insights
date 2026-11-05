import SwiftData
import SwiftUI

/// Sync status, Health access and how the app treats your data.
struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncController.self) private var syncController
    @Query private var anchors: [SyncAnchorRecord]

    private var lastSynced: Date? { anchors.map(\.lastSynced).max() }

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Health") {
                    LabeledContent("Last synced", value: lastSyncedText)
                    if SyncController.canSync {
                        Button(syncController.isSyncing ? "Syncing…" : "Sync now") {
                            Task { await syncController.sync(context: modelContext) }
                        }
                        .disabled(syncController.isSyncing)
                    }
                    if let errorMessage = syncController.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Theme.amberText)
                    }
                }

                Section {
                    Text("Insights only reads from Apple Health. To change what it can read, open "
                         + "Settings › Privacy & Security › Health › Insights.")
                        .foregroundStyle(Theme.bodySecondary)
                } header: {
                    Text("Access")
                }

                Section {
                    Text("Everything is worked out on this iPhone. Wording is done by Apple's "
                         + "on-device model when it is available. No health data leaves the device.")
                        .foregroundStyle(Theme.bodySecondary)
                } header: {
                    Text("Privacy")
                }

                if SyncController.isShowingSampleData {
                    Section {
                        Text("Sample data is on. These are invented numbers, not your Health data.")
                            .foregroundStyle(Theme.amberText)
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }

    private var lastSyncedText: String {
        if SyncController.isShowingSampleData { return "Sample data" }
        guard let lastSynced else { return "Never" }
        return lastSynced.formatted(date: .abbreviated, time: .shortened)
    }
}

#if DEBUG
#Preview {
    ProfileView()
        .environment(SyncController())
        .modelContainer(SampleData.container())
}
#endif
