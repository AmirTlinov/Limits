import Foundation
import Testing
@testable import LimitsCore

@Test func codexRuntimePathKeepsShellPathAndAddsNodeFallbacks() {
    let path = CodexExecutableLocator.resolvedPath(
        shellPath: "/custom/bin:/usr/bin",
        basePath: "/base/bin:/usr/bin"
    )
    let segments = path.split(separator: ":").map(String.init)

    #expect(segments.first == "/custom/bin")
    #expect(segments.contains("/base/bin"))
    #expect(segments.contains(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/fnm/aliases/default/bin").path))
    #expect(segments.contains(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".volta/bin").path))
    #expect(segments.allSatisfy { !$0.contains("/.local/state/fnm_multishells") })
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

@Test func nativeCodexExecutableDoesNotRequireNodeButNodeScriptDoes() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-codex-kind-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let native = root.appending(path: "native-codex")
    let script = root.appending(path: "script-codex")
    try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]).write(to: native)
    try Data("#!/usr/bin/env node\nconsole.log('codex')\n".utf8).write(to: script)

    #expect(!CodexExecutableLocator.requiresNode(native))
    #expect(CodexExecutableLocator.requiresNode(script))
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

    #expect(CodexSessionPresentation.rateLimitSections(probe: nil, now: .now).isEmpty)
    #expect(CodexSessionPresentation.panelSummary(probe: nil, now: .now) == nil)
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
    let probe = CodexSessionProbe(
        fingerprint: "fingerprint",
        email: "live@example.com",
        planType: "pro",
        rateLimit: liveSnapshot,
        rateLimitsByLimitId: nil,
        validatedAt: .distantPast
    )

    let row = try #require(CodexSessionPresentation.rateLimitSections(probe: probe, now: .distantPast).first?.rows.first)
    #expect(row.remainingPercent == 88)
    #expect(CodexSessionPresentation.panelSummary(probe: probe, now: .distantPast) != nil)
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
    let staleProbe = CodexSessionProbe(
        fingerprint: "fingerprint",
        email: "stale@example.com",
        planType: "pro",
        rateLimit: staleLiveSnapshot,
        rateLimitsByLimitId: nil,
        validatedAt: .distantPast
    )

    #expect(CodexSessionPresentation.rateLimitSections(probe: staleProbe, probeError: "validation failed", now: .distantPast).isEmpty)
    #expect(CodexSessionPresentation.panelSummary(probe: staleProbe, probeError: "validation failed", now: .distantPast) == nil)
    #expect(CodexSessionPresentation.rateLimitSections(probe: staleProbe, now: .distantPast).isEmpty == false)
}
