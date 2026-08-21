import Foundation
import Testing
@testable import LimitsCore

@Test func rolloutContextKeepsGitRepositoryAsProjectAndUsesTheExplicitUserRequestAsTask() throws {
    let file = try rolloutContextFixture(
        """
        {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread","cwd":"/tmp/worktree","git":{"repository_url":"https://github.com/AmirTlinov/Limits.git"}}}
        {"timestamp":"2026-08-21T00:00:10Z","type":"event_msg","payload":{"type":"user_message","message":"# Files mentioned\\nfixture.png\\n\\n## My request:\\nFix the token chart"}}
        {"timestamp":"2026-08-21T00:00:20Z","type":"turn_context","payload":{"turn_id":"turn","cwd":"/tmp/worktree"}}
        """
    )
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let contexts = try CodexRolloutContextParser.parse(file: file)
    let turn = try #require(contexts.first { $0.turnID == "turn" })
    #expect(turn.projectID == "https://github.com/AmirTlinov/Limits.git")
    #expect(turn.projectTitle == "Limits")
    #expect(turn.taskTitle == "Fix the token chart")
}

@Test func rolloutContextUsesTheTurnsCWDWhenNoRepositoryIdentityExists() throws {
    let file = try rolloutContextFixture(
        """
        {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread","cwd":"/tmp/first"}}
        {"timestamp":"2026-08-21T00:00:20Z","type":"turn_context","payload":{"turn_id":"turn","cwd":"/tmp/second"}}
        """
    )
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let contexts = try CodexRolloutContextParser.parse(file: file)
    let turn = try #require(contexts.first { $0.turnID == "turn" })
    #expect(turn.projectID == "/tmp/second")
    #expect(turn.projectTitle == "second")
}

private func rolloutContextFixture(_ contents: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-rollout-context-parser-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "rollout.jsonl")
    try (contents + "\n").write(to: file, atomically: true, encoding: .utf8)
    return file
}
