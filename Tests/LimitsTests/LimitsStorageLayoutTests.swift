import Foundation
import Testing
@testable import LimitsCore

@Test func isolatedStorageLayoutKeepsEveryWritableFileUnderTestRootAndUsesMemoryCredentials() {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-layout-\(UUID().uuidString)", directoryHint: .isDirectory)
    let layout = LimitsStorageLayout.isolated(root: root)

    #expect(layout.isIsolated)
    #expect(layout.credentialStorage == .memoryOnly)
    #expect(
        layout.stateDirectory
            == root.appending(path: "Application Support/Limits", directoryHint: .isDirectory)
    )
    #expect(layout.codexHome == root.appending(path: "Codex", directoryHint: .isDirectory))
    #expect(layout.homeDirectory == root.appending(path: "Home", directoryHint: .isDirectory))
    #expect(layout.widgetDirectory == root.appending(path: "AppGroup", directoryHint: .isDirectory))
    #expect(layout.pricingFixtureDirectory == root.appending(path: "Pricing", directoryHint: .isDirectory))
    #expect(layout.containsEveryWritableFileInIsolatedRoot())
}

@Test func productionStorageLayoutUsesSystemCredentialsAndCanonicalOwners() {
    let layout = LimitsStorageLayout.production()

    #expect(!layout.isIsolated)
    #expect(layout.credentialStorage == .systemKeychain)
    #expect(layout.stateDirectory.lastPathComponent == "Limits")
    #expect(layout.codexAuthURL.lastPathComponent == "auth.json")
    #expect(layout.codexAuthURL.deletingLastPathComponent().lastPathComponent == ".codex")
    #expect(layout.claudeGlobalLockURL.deletingLastPathComponent() == layout.stateDirectory)
}
