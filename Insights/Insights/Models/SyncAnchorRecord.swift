import Foundation
import SwiftData

/// Apple Health's bookmark for one sample type, kept between launches. Having
/// one means "you have seen everything up to here". Having none means we have
/// never synced that type, so the next sync fetches the lot.
@Model
final class SyncAnchorRecord {
    // which sample type this bookmark belongs to: "heartRate", "sleep"
    var typeKey: String

    // the anchor packed into bytes, since SwiftData cannot store it directly
    var anchorData: Data

    var lastSynced: Date

    init(typeKey: String, anchorData: Data, lastSynced: Date) {
        self.typeKey = typeKey
        self.anchorData = anchorData
        self.lastSynced = lastSynced
    }
}
