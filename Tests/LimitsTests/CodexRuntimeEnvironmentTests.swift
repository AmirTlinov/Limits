import Foundation
import Testing
@testable import Limits

@Test func codexRuntimePathKeepsShellPathAndAddsNodeFallbacks() {
    let path = CodexExecutableLocator.resolvedPath(
        shellPath: "/custom/bin:/usr/bin",
        basePath: "/base/bin:/usr/bin"
    )
    let segments = path.split(separator: ":").map(String.init)

    #expect(segments.first == "/custom/bin")
    #expect(segments.contains("/base/bin"))
    #expect(segments.contains(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".volta/bin").path))
    #expect(segments.contains("/opt/homebrew/bin"))
    #expect(segments.contains("/usr/local/bin"))
    #expect(segments.contains("/usr/bin"))
    #expect(Set(segments).count == segments.count)
}

@Test func codexRuntimeEnvironmentContainsResolvedPath() {
    let environment = CodexExecutableLocator.resolvedEnvironment(
        shellPath: "/shell/bin",
        baseEnvironment: ["PATH": "/base/bin", "HOME": "/tmp/home"]
    )

    #expect(environment["HOME"] == "/tmp/home")
    #expect(environment["PATH"]?.hasPrefix("/shell/bin:/base/bin") == true)
    #expect(environment["PATH"]?.contains("/.volta/bin") == true)
}

@MainActor
@Test func currentCLILiveSectionsDoNotUseStoredSnapshotsWhenProbeIsMissing() {
    let staleStoredSnapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "stored",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: nil, usedPercent: 91, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    #expect(AppModel.liveCurrentCLIRateLimitSections(probe: nil).isEmpty)
    #expect(AppModel.liveCurrentCLIPanelSummary(probe: nil) == nil)
    #expect(RateLimitDisplayBuilder.makeSections(primary: staleStoredSnapshot, byLimitId: nil).isEmpty == false)
}

@MainActor
@Test func currentCLILiveSectionsUseProbeSnapshotsWhenPresent() throws {
    let liveSnapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "live",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: nil, usedPercent: 12, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let probe = AppModel.CurrentCLIProbe(
        fingerprint: "fingerprint",
        email: "live@example.com",
        planType: "pro",
        rateLimit: liveSnapshot,
        rateLimitsByLimitId: nil,
        validatedAt: .distantPast
    )

    let row = try #require(AppModel.liveCurrentCLIRateLimitSections(probe: probe).first?.rows.first)
    #expect(row.remainingPercent == 88)
    #expect(AppModel.liveCurrentCLIPanelSummary(probe: probe) != nil)
}

@MainActor
@Test func currentCLILiveSectionsIgnoreStaleProbeWhenProbeErrorExists() {
    let staleLiveSnapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "stale-live",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: nil, usedPercent: 12, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let staleProbe = AppModel.CurrentCLIProbe(
        fingerprint: "fingerprint",
        email: "stale@example.com",
        planType: "pro",
        rateLimit: staleLiveSnapshot,
        rateLimitsByLimitId: nil,
        validatedAt: .distantPast
    )

    #expect(AppModel.liveCurrentCLIRateLimitSections(probe: staleProbe, probeError: "validation failed").isEmpty)
    #expect(AppModel.liveCurrentCLIPanelSummary(probe: staleProbe, probeError: "validation failed") == nil)
    #expect(AppModel.liveCurrentCLIRateLimitSections(probe: staleProbe).isEmpty == false)
}
