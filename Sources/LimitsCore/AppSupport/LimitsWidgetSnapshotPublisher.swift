import Foundation
import LimitsShared
import WidgetKit

public struct LimitsWidgetSnapshotPublisher {
    private let store: LimitsWidgetSnapshotStore
    private let reloadTimelines: () -> Void

    public init(
        store: LimitsWidgetSnapshotStore = LimitsWidgetSnapshotStore(),
        reloadTimelines: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: LimitsWidgetConstants.widgetKind)
        }
    ) {
        self.store = store
        self.reloadTimelines = reloadTimelines
    }

    @discardableResult
    public func publish(_ snapshot: LimitsWidgetSnapshot) throws -> Bool {
        if let current = try store.readSnapshot(),
           current.schemaVersion == snapshot.schemaVersion,
           current.providers == snapshot.providers {
            return false
        }
        try store.writeSnapshot(snapshot)
        reloadTimelines()
        return true
    }
}
