import Foundation
import SwiftData

/// HealthKit's bookmark for one sample type, saved between launches
/// an anchor means "you've seen everything up to here"
/// no anchor for a type means we've never synced it, so do the full fetch
@Model
final class SyncAnchorRecord {
    /// Which sample type this bookmark belongs to, e.g. "heartRate" or "sleep"
    var typeKey: String // heartRate, sleep

    /// The HKQueryAnchor archived to bytes, SwiftData can't store it directly
    var anchorData: Data

    var lastSynced: Date

    init(typeKey: String, anchorData: Data, lastSynced: Date) {
        self.typeKey = typeKey
        self.anchorData = anchorData
        self.lastSynced = lastSynced
    }
}
