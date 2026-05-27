import Foundation
import LimitsShared
import WidgetKit

struct LimitsWidgetSnapshotPublisher {
    private let store: LimitsWidgetSnapshotStore
    private let reloadTimelines: () -> Void

    init(
        store: LimitsWidgetSnapshotStore = LimitsWidgetSnapshotStore(),
        reloadTimelines: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: LimitsWidgetConstants.widgetKind)
        }
    ) {
        self.store = store
        self.reloadTimelines = reloadTimelines
    }

    func publish(_ snapshot: LimitsWidgetSnapshot) throws {
        try store.writeSnapshot(snapshot)
        reloadTimelines()
    }
}
