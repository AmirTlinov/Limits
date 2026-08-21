import Foundation
import Testing
@testable import LimitsCore

@Test func rolloutImporterStreamsCumulativeCountersHandlesResetAndDeduplicates() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-rollout-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Codex", directoryHint: .isDirectory)
    let sessionDirectory = codexHome.appending(path: "sessions/2026/08/21", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let file = sessionDirectory.appending(path: "rollout.jsonl")
    try fixtureLines().write(to: file, atomically: true, encoding: .utf8)

    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root.appending(path: "Data")))
    _ = try await repository.open()
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_confirmed",
        fingerprint: "fingerprint",
        observedAt: try Date("2026-08-21T00:00:00Z", strategy: .iso8601),
        transition: .observed
    )
    let importer = CodexRolloutUsageImporter(repository: repository, codexHome: codexHome)

    let first = await importer.importChangedFiles()
    let second = await importer.importChangedFiles()
    let snapshot = try await repository.snapshot()

    #expect(first.importedEvents == 2)
    #expect(first.unreadableFiles == 0)
    #expect(second.importedEvents == 0)
    #expect(snapshot.dailyUsage.reduce(0) { $0 + $1.usage.totalTokens } == 225)
    #expect(snapshot.dailyUsage.allSatisfy { $0.accountID == "acct_confirmed" })
    #expect(Set(snapshot.dailyUsage.map(\.modelID)) == ["gpt-5.6-sol", "gpt-5.6-terra"])
    let sol = try #require(snapshot.dailyUsage.first { $0.modelID == "gpt-5.6-sol" })
    #expect(sol.usage.inputTokens == 180)
    #expect(sol.usage.cachedInputTokens == 40)
    #expect(sol.usage.outputTokens == 20)
    #expect(sol.usage.reasoningOutputTokens == 8)
}

@Test func rolloutImporterKeepsIncompleteTurnInCursorUntilCompletion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-rollout-cursor-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Codex", directoryHint: .isDirectory)
    let sessionDirectory = codexHome.appending(path: "sessions/2026/08/21", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let file = sessionDirectory.appending(path: "active.jsonl")
    let active = """
    {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread-active"}}
    {"timestamp":"2026-08-21T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-active","model":"gpt-5.6-luna","effort":"medium"}}
    {"timestamp":"2026-08-21T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":10,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":55}}}}
    """ + "\n"
    try active.write(to: file, atomically: true, encoding: .utf8)
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root.appending(path: "Data")))
    _ = try await repository.open()
    let importer = CodexRolloutUsageImporter(repository: repository, codexHome: codexHome)

    #expect(await importer.importChangedFiles().importedEvents == 0)
    let completion = """
    {"timestamp":"2026-08-21T00:03:00Z","type":"event_msg","payload":{"type":"task_complete"}}
    """ + "\n"
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(completion.utf8))
    try handle.close()

    #expect(await importer.importChangedFiles().importedEvents == 1)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.first?.accountID == nil)
    #expect(snapshot.dailyUsage.first?.attribution == .unattributed)
    #expect(snapshot.dailyUsage.first?.usage.totalTokens == 55)
}

@Test func rolloutImporterKeepsUsageBeforeAndAfterRerouteOnItsBilledModel() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-rollout-reroute-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Codex", directoryHint: .isDirectory)
    let sessionDirectory = codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let file = sessionDirectory.appending(path: "rerouted.jsonl")
    let contents = """
    {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread-rerouted"}}
    {"timestamp":"2026-08-21T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-rerouted","model":"gpt-5.6-sol"}}
    {"timestamp":"2026-08-21T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":100}}}}
    {"timestamp":"2026-08-21T00:03:00Z","type":"event_msg","payload":{"type":"model_reroute","billed_model":"gpt-5.6-terra"}}
    {"timestamp":"2026-08-21T00:04:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":150}}}}
    {"timestamp":"2026-08-21T00:05:00Z","type":"event_msg","payload":{"type":"task_complete"}}
    """ + "\n"
    try contents.write(to: file, atomically: true, encoding: .utf8)
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root.appending(path: "Data")))
    _ = try await repository.open()
    let importer = CodexRolloutUsageImporter(repository: repository, codexHome: codexHome)

    #expect(await importer.importChangedFiles().importedEvents == 2)
    let snapshot = try await repository.snapshot()
    let sol = try #require(snapshot.dailyUsage.first { $0.modelID == "gpt-5.6-sol" })
    let terra = try #require(snapshot.dailyUsage.first { $0.modelID == "gpt-5.6-terra" })
    #expect(sol.usage.totalTokens == 100)
    #expect(terra.usage.totalTokens == 50)
    #expect(sol.usage.reasoningOutputTokens == 2)
    #expect(terra.usage.reasoningOutputTokens == 3)
}

@Test func rolloutImporterCommitsAnAbortedActiveTurn() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-rollout-aborted-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Codex", directoryHint: .isDirectory)
    let sessionDirectory = codexHome.appending(path: "sessions/2026/08/21", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let file = sessionDirectory.appending(path: "aborted.jsonl")
    let contents = """
    {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread-aborted"}}
    {"timestamp":"2026-08-21T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-aborted","model":"gpt-5.6-luna"}}
    {"timestamp":"2026-08-21T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":45}}}}
    {"timestamp":"2026-08-21T00:03:00Z","type":"event_msg","payload":{"type":"turn_aborted"}}
    """ + "\n"
    try contents.write(to: file, atomically: true, encoding: .utf8)
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root.appending(path: "Data")))
    _ = try await repository.open()
    let importer = CodexRolloutUsageImporter(repository: repository, codexHome: codexHome)

    #expect(await importer.importChangedFiles().importedEvents == 1)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.first?.modelID == "gpt-5.6-luna")
    #expect(snapshot.dailyUsage.first?.usage.totalTokens == 45)
}

@Test func rolloutImporterClassifiesEachNumericRequestBeforeDailyAggregation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-rollout-context-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Codex", directoryHint: .isDirectory)
    let sessionDirectory = codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let file = sessionDirectory.appending(path: "context.jsonl")
    let contents = """
    {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread-context"}}
    {"timestamp":"2026-08-21T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-context","model":"gpt-5.6-sol"}}
    {"timestamp":"2026-08-21T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10000,"reasoning_output_tokens":2000,"total_tokens":210000}}}}
    {"timestamp":"2026-08-21T00:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":30000,"reasoning_output_tokens":5000,"total_tokens":530000}}}}
    {"timestamp":"2026-08-21T00:04:00Z","type":"event_msg","payload":{"type":"task_complete"}}
    """ + "\n"
    try contents.write(to: file, atomically: true, encoding: .utf8)
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root.appending(path: "Data")))
    _ = try await repository.open()
    _ = try await repository.recordRateCardRevision(OpenAIPricingCatalog.bundledRevision)
    let importer = CodexRolloutUsageImporter(repository: repository, codexHome: codexHome)

    #expect(await importer.importChangedFiles().importedEvents == 1)
    let rows = try await repository.snapshot().dailyUsage
    #expect(Set(rows.map(\.contextTier)) == [.standard, .long])
    #expect(rows.first { $0.contextTier == .standard }?.usage.totalTokens == 210_000)
    #expect(rows.first { $0.contextTier == .long }?.usage.totalTokens == 320_000)
}

private func fixtureLines() -> String {
    """
    {"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"session_id":"thread-1"}}
    {"timestamp":"2026-08-21T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6-sol","effort":"high"}}
    {"timestamp":"2026-08-21T00:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":4,"total_tokens":110}}}}
    {"timestamp":"2026-08-21T00:20:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":8,"total_tokens":200}}}}
    {"timestamp":"2026-08-21T00:21:00Z","type":"turn_context","payload":{"turn_id":"turn-2","model":"gpt-5.6-sol","effort":"medium"}}
    {"timestamp":"2026-08-21T00:22:00Z","type":"event_msg","payload":{"type":"model_reroute","billed_model":"gpt-5.6-terra"}}
    {"timestamp":"2026-08-21T00:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":25}}}}
    {"timestamp":"2026-08-21T00:31:00Z","type":"event_msg","payload":{"type":"task_complete"}}
    """ + "\n"
}
