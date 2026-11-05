import SwiftData
import SwiftUI

/// The app's four tabs. The tab bar is the system one, which iOS draws in
/// Liquid Glass.
///
/// - Summary: the designed home screen
/// - Trends: every cached metric, raw, including the five without a tile
/// - Reports: the full ranked findings with the ranker's workings
/// - Profile: sync, Health access and privacy
struct RootView: View {
    @State private var syncController = SyncController()

    var body: some View {
        TabView {
            Tab("Summary", systemImage: "sun.horizon") {
                SummaryView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line") {
                ContentView()
            }
            Tab("Reports", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    FindingsView()
                }
            }
            Tab("Profile", systemImage: "person.crop.circle") {
                ProfileView()
            }
        }
        .tint(Theme.accent)
        .environment(syncController)
        // FINAL-PLAN specifies a light canvas only; a dark variant is not
        // designed yet
        .preferredColorScheme(.light)
    }
}

#if DEBUG
#Preview {
    RootView()
        .modelContainer(SampleData.container())
}
#endif
