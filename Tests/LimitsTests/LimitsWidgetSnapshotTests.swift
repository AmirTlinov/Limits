import Foundation
import LimitsShared
import Testing
@testable import LimitsCore

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
                observedAt: generatedAt,
                freshUntil: generatedAt.addingTimeInterval(900),
                note: nil
            ),
        ]
    )

    let store = LimitsWidgetSnapshotStore(baseURL: root)
    try store.writeSnapshot(snapshot)

    #expect(try store.readSnapshot() == snapshot)
    #expect(try store.snapshotURL().lastPathComponent == LimitsWidgetConstants.snapshotFileName)
    #expect(posixPermissions(at: try store.snapshotURL().deletingLastPathComponent()) == 0o700)
    #expect(posixPermissions(at: try store.snapshotURL()) == 0o600)
}

@Test func widgetV1SnapshotDecodesAsStaleInsteadOfTrustingGeneratedAt() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-10T00:00:00Z",
          "providers": [{
            "id": "codex",
            "title": "Codex",
            "status": "available",
            "limits": [{"id":"five","title":"5h","remainingPercent":88}],
            "updatedAt": "2026-07-10T00:00:00Z"
          }]
        }
        """.utf8
    )

    let snapshot = try JSONDecoder.limitsWidget.decode(LimitsWidgetSnapshot.self, from: data)
    let provider = try #require(snapshot.provider(.codex))

    #expect(snapshot.schemaVersion == 1)
    #expect(provider.observedAt != nil)
    #expect(provider.freshUntil == nil)
    #expect(!provider.isFresh(at: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(provider.limitsForCompactSurface(at: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
}

@Test func compactSurfaceFreshnessExpiresAtTTLOrFirstReset() {
    let observedAt = Date(timeIntervalSince1970: 10_000)
    let earlyReset = observedAt.addingTimeInterval(120)

    #expect(
        LimitsFreshnessPolicy.freshUntil(
            observedAt: observedAt,
            limitResetDates: [earlyReset],
            ttl: 900
        ) == earlyReset
    )
    #expect(
        LimitsFreshnessPolicy.freshUntil(
            observedAt: observedAt,
            limitResetDates: [],
            ttl: 900
        ) == observedAt.addingTimeInterval(900)
    )
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

    let limits = WidgetPresentationPolicy.limitSnapshots(from: [section], now: now)

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
                observedAt: nil,
                freshUntil: nil,
                note: "No live limit data yet."
            ),
        ]
    )

    let json = String(decoding: try JSONEncoder.limitsWidget.encode(snapshot), as: UTF8.self).lowercased()

    #expect(!json.contains("token"))
    #expect(!json.contains("authfingerprint"))
    #expect(!json.contains("keychain"))
    #expect(!json.contains("credential"))
    #expect(!json.contains("updatedat"))
}

@Test func widgetPublisherReloadsTimelineOnlyWhenProviderEvidenceChanges() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-widget-publisher-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LimitsWidgetSnapshotStore(baseURL: root)
    var reloadCount = 0
    let publisher = LimitsWidgetSnapshotPublisher(store: store) {
        reloadCount += 1
    }
    let observedAt = Date(timeIntervalSince1970: 10_000)
    let provider = LimitsWidgetProviderSnapshot(
        id: .codex,
        title: "Codex",
        subtitle: nil,
        status: .available,
        limits: [LimitsWidgetLimitSnapshot(id: "five", title: "5h", remainingPercent: 80, resetDate: nil)],
        observedAt: observedAt,
        freshUntil: observedAt.addingTimeInterval(900),
        note: nil
    )
    let first = LimitsWidgetSnapshot(generatedAt: observedAt, providers: [provider])
    let sameEvidenceLater = LimitsWidgetSnapshot(generatedAt: observedAt.addingTimeInterval(30), providers: [provider])
    let changed = LimitsWidgetSnapshot(
        generatedAt: observedAt.addingTimeInterval(60),
        providers: [
            LimitsWidgetProviderSnapshot(
                id: .codex,
                title: "Codex",
                subtitle: nil,
                status: .error,
                limits: provider.limits,
                observedAt: observedAt,
                freshUntil: observedAt.addingTimeInterval(900),
                note: "refresh failed"
            ),
        ]
    )

    #expect(try publisher.publish(first))
    #expect(try !publisher.publish(sameEvidenceLater))
    #expect(try publisher.publish(changed))
    #expect(reloadCount == 2)
}

private func posixPermissions(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
