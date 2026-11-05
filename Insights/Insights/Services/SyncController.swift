import Foundation
import Observation
import SwiftData

/// The one place a sync is started from, shared by every screen, so two tabs
/// can never run overlapping syncs or disagree about whether one is running.
@Observable
final class SyncController {
    private let healthKit = HealthKitService()

    private(set) var isSyncing = false

    /// set when the permission request itself failed; cleared by the next
    /// successful sync
    private(set) var errorMessage: String?

    // opening the app, or switching back to it, syncs only when the last sync
    // is older than this, so flicking between tabs never re-reads Health
    static let automaticSyncInterval: TimeInterval = 15 * 60

    /// true only on a `-sampleData` run, always false in a release build.
    /// Syncing then would pour the simulator's own Health data into the
    /// invented history.
    static var isShowingSampleData: Bool {
        #if DEBUG
        SampleData.isEnabled
        #else
        false
        #endif
    }

    /// whether this device can sync at all
    static var canSync: Bool {
        !isShowingSampleData && HealthKitService.isAvailable
    }

    /// Asks for permission (a no-op after the first time), then syncs.
    func sync(context: ModelContext) async {
        guard Self.canSync, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await healthKit.requestAuthorization()
            await SyncService(healthKit: healthKit, context: context).sync()
            errorMessage = nil
        } catch {
            errorMessage = "Authorisation failed: \(error.localizedDescription)"
        }
    }

    /// Syncs only if the last one is old. Never the first one: that waits
    /// for the user to press Connect, so they read what the app does with
    /// their Health data before the permission sheet appears.
    func syncIfStale(context: ModelContext, lastSynced: Date?, asOf now: Date = .now) async {
        guard let lastSynced,
              now.timeIntervalSince(lastSynced) >= Self.automaticSyncInterval else {
            return
        }
        await sync(context: context)
    }
}
