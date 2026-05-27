import Foundation
import LimitsShared
import Testing
@testable import Limits

@Test func widgetSnapshotStoreRoundTripsCurrentLimitsJSON() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-widget-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let generatedAt = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 27, hour: 8)))
    let snapshot = LimitsWidgetSnapshot(
        generatedAt: generatedAt,
        providers: [
            LimitsWidgetProviderSnapshot(
                id: .codex,
                title: "Codex Pro",
                subtitle: "example@example.com",
                status: .available,
                limits: [
                    LimitsWidgetLimitSnapshot(id: "codex.five_hour", title: "5h", remainingPercent: 72, resetDate: generatedAt.addingTimeInterval(3_600)),
                ],
                updatedAt: generatedAt,
                note: nil
            ),
        ]
    )

    let store = LimitsWidgetSnapshotStore(baseURL: root)
    try store.writeSnapshot(snapshot)

    #expect(try store.readSnapshot() == snapshot)
    #expect(try store.snapshotURL().lastPathComponent == LimitsWidgetConstants.snapshotFileName)
}

@Test func widgetLimitSnapshotsDoNotPresentExpiredResetAsCurrentPercent() throws {
    let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 27, hour: 8)))
    let section = RateLimitDisplaySection(
        id: "codex",
        title: "Codex CLI",
        rows: [
            RateLimitDisplayRow(
                id: "five_hour",
                title: "5h",
                usedPercent: 25,
                resetText: nil,
                resetDate: now.addingTimeInterval(-60)
            ),
            RateLimitDisplayRow(
                id: "weekly",
                title: "Weekly",
                usedPercent: 40,
                resetText: nil,
                resetDate: now.addingTimeInterval(60)
            ),
        ]
    )

    let limits = AppModel.widgetLimitSnapshots(from: [section], now: now)

    #expect(limits[0].remainingPercent == nil)
    #expect(limits[1].remainingPercent == 60)
}

@Test func widgetSnapshotJSONCarriesNoCredentialShapedFields() throws {
    let snapshot = LimitsWidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_779_876_000),
        providers: [
            LimitsWidgetProviderSnapshot(
                id: .claude,
                title: "Claude Max",
                subtitle: "example@example.com",
                status: .noData,
                limits: [],
                updatedAt: nil,
                note: "No live limit data yet."
            ),
        ]
    )

    let json = String(decoding: try JSONEncoder.limitsWidget.encode(snapshot), as: UTF8.self).lowercased()

    #expect(!json.contains("token"))
    #expect(!json.contains("authfingerprint"))
    #expect(!json.contains("keychain"))
    #expect(!json.contains("credential"))
}
