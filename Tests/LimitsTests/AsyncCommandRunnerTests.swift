import Foundation
import Testing
@testable import LimitsCore

@Test func asyncCommandRunnerCapturesOutputAndExitStatus() async throws {
    let result = try await AsyncCommandRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'ready'; printf 'detail' >&2; exit 7"],
        timeout: 2
    )

    #expect(result.terminationStatus == 7)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "ready")
    #expect(String(decoding: result.standardError, as: UTF8.self) == "detail")
}

@Test func asyncCommandRunnerTerminatesTimedOutProcess() async throws {
    let startedAt = Date()

    do {
        _ = try await AsyncCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10"],
            timeout: 0.05
        )
        Issue.record("Expected timeout")
    } catch AsyncCommandRunnerError.timedOut(let timeout) {
        #expect(timeout == 0.05)
    }

    #expect(Date().timeIntervalSince(startedAt) < 2)
}

@Test func claudeAuthStatusUsesAsyncCommandRunner() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-claude-status-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appending(path: "claude-test")
    let script = """
    #!/bin/sh
    printf '{"loggedIn":true,"email":"user@example.com","orgId":"org_1","subscriptionType":"max"}'
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let status = try await ClaudeAuthStatusService(executableURL: executable, timeout: 5).readStatus()

    #expect(status.loggedIn)
    #expect(status.stableIdentity == ClaudeAccountIdentity(email: "user@example.com", organizationId: "org_1"))
}
