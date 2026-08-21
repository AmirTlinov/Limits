import Darwin
import Foundation

public struct CodexRolloutImportReport: Hashable, Sendable {
    public let scannedFiles: Int
    public let importedEvents: Int
    public let unreadableFiles: Int

    public init(scannedFiles: Int, importedEvents: Int, unreadableFiles: Int) {
        self.scannedFiles = scannedFiles
        self.importedEvents = importedEvents
        self.unreadableFiles = unreadableFiles
    }
}

public protocol CodexRolloutImporting: Sendable {
    func importChangedFiles() async -> CodexRolloutImportReport
}

public actor CodexRolloutUsageImporter: CodexRolloutImporting {
    public static let schemaAdapter = 1

    private let repository: CodexUsageRepository
    private let roots: [URL]
    private let fileManager: SendableFileManager

    public init(
        repository: CodexUsageRepository,
        codexHome: URL,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.fileManager = SendableFileManager(fileManager)
        roots = [
            codexHome.appending(path: "sessions", directoryHint: .isDirectory),
            codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory),
        ]
    }

    public func importChangedFiles() async -> CodexRolloutImportReport {
        await Self.performImport(repository: repository, roots: roots, fileManager: fileManager.value)
    }

    private static func performImport(
        repository: CodexUsageRepository,
        roots: [URL],
        fileManager: FileManager
    ) async -> CodexRolloutImportReport {
        var scanned = 0
        var imported = 0
        var unreadable = 0
        let files = rolloutFiles(under: roots, fileManager: fileManager)
        let rateCardRevisions = (try? await repository.snapshot().rateCardRevisions) ?? []
        for file in files {
            guard !Task.isCancelled else { break }
            scanned += 1
            do {
                imported += try await importFile(
                    file,
                    repository: repository,
                    fileManager: fileManager,
                    rateCardRevisions: rateCardRevisions
                )
            } catch {
                unreadable += 1
            }
        }
        try? await repository.purgeRawEvents()
        return CodexRolloutImportReport(scannedFiles: scanned, importedEvents: imported, unreadableFiles: unreadable)
    }

    private static func rolloutFiles(under roots: [URL], fileManager: FileManager) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        return roots.flatMap { root -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { value -> URL? in
                guard let url = value as? URL, url.pathExtension == "jsonl" else { return nil }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return url
            }
        }
        .sorted { $0.path < $1.path }
    }

    private static func importFile(
        _ file: URL,
        repository: CodexUsageRepository,
        fileManager: FileManager,
        rateCardRevisions: [OpenAIRateCardRevision]
    ) async throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? .distantPast
        let storedCursor = try await repository.importCursor(for: file.path)
        let canResume = storedCursor?.inode == inode
            && storedCursor?.schemaAdapter == schemaAdapter
            && (storedCursor?.byteOffset ?? 0) <= size
        let startOffset = canResume ? (storedCursor?.byteOffset ?? 0) : 0
        var state = canResume
            ? storedCursor?.parserState.flatMap { try? JSONDecoder.limits.decode(ParserState.self, from: $0) } ?? ParserState()
            : ParserState()

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return 0 }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return 0 }
        let completeData = data[data.startIndex...lastNewline]
        let consumedBytes = UInt64(completeData.count)
        var pendingEvents: [ParsedEvent] = []

        for line in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            parse(object, state: &state, emitted: &pendingEvents)
        }
        if file.path.contains("/archived_sessions/") {
            flushPending(state: &state, into: &pendingEvents)
        }

        var events: [CodexUsageEvent] = []
        events.reserveCapacity(pendingEvents.count)
        for event in pendingEvents where event.usage.totalTokens > 0 {
            let accountID = try await repository.accountID(at: event.occurredAt)
            events.append(
                CodexUsageEvent(
                    threadID: event.threadID,
                    turnID: event.turnID,
                    counterEpoch: event.counterEpoch,
                    occurredAt: event.occurredAt,
                    accountID: accountID,
                    requestedModel: event.requestedModel,
                    billedModel: event.billedModel,
                    reasoningEffort: event.reasoningEffort,
                    speed: event.speed,
                    usage: event.usage,
                    contextBreakdown: contextBreakdown(
                        for: event,
                        rateCardRevisions: rateCardRevisions
                    ),
                    attribution: accountID == nil ? .unattributed : .confirmed,
                    source: .localRollout
                )
            )
        }
        let inserted = try await repository.recordUsageEvents(events)
        let stateData = try JSONEncoder.limits.encode(state)
        try await repository.saveImportCursor(
            CodexImportCursor(
                path: file.path,
                inode: inode,
                byteOffset: startOffset + consumedBytes,
                modifiedAt: modifiedAt,
                schemaAdapter: schemaAdapter,
                parserState: stateData
            )
        )
        return inserted
    }

    private static func parse(
        _ envelope: [String: Any],
        state: inout ParserState,
        emitted: inout [ParsedEvent]
    ) {
        guard let type = envelope["type"] as? String, let payload = envelope["payload"] as? [String: Any] else { return }
        let timestamp = (envelope["timestamp"] as? String).flatMap(parseDate)

        switch type {
        case "session_meta":
            state.threadID = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? state.threadID
        case "turn_context":
            flushPending(state: &state, into: &emitted)
            state.turnID = payload["turn_id"] as? String
            state.requestedModel = payload["model"] as? String
            state.reasoningEffort = (payload["effort"] as? String)
                ?? ((payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["reasoning_effort"] as? String
            state.speed = payload["speed"] as? String
            state.billedModel = nil
        case "event_msg":
            guard let eventType = payload["type"] as? String else { return }
            if eventType == "token_count" {
                guard
                    let info = payload["info"] as? [String: Any],
                    let total = info["total_token_usage"] as? [String: Any],
                    let usage = usage(from: total)
                else { return }
                append(usage: usage, at: timestamp ?? .distantPast, state: &state, emitted: &emitted)
            } else if ["model_reroute", "model_rerouted", "reroute"].contains(eventType) {
                if state.pendingUsage.totalTokens > 0 {
                    flushPending(state: &state, into: &emitted)
                    state.counterEpoch += 1
                }
                state.billedModel = (payload["billed_model"] as? String)
                    ?? (payload["billedModel"] as? String)
                    ?? (payload["model"] as? String)
                    ?? (payload["to"] as? String)
            } else if ["task_complete", "task_completed", "turn_aborted"].contains(eventType) {
                flushPending(state: &state, into: &emitted)
            }
        default:
            break
        }
    }

    private static func append(
        usage cumulative: CodexTokenUsage,
        at date: Date,
        state: inout ParserState,
        emitted: inout [ParsedEvent]
    ) {
        guard state.threadID != nil, state.turnID != nil else { return }
        let delta: CodexTokenUsage
        if let previous = state.previousCumulative, let monotonic = cumulative.monotonicDelta(from: previous) {
            delta = monotonic
        } else if state.previousCumulative != nil {
            flushPending(state: &state, into: &emitted)
            state.counterEpoch += 1
            delta = cumulative
        } else {
            delta = cumulative
        }
        state.previousCumulative = cumulative
        if state.pendingRequestUsages == nil {
            state.pendingUnclassifiedUsage = state.pendingUsage
            state.pendingRequestUsages = []
        }
        state.pendingUsage = state.pendingUsage + delta
        state.pendingRequestUsages?.append(delta)
        state.pendingOccurredAt = date
    }

    private static func flushPending(state: inout ParserState, into emitted: inout [ParsedEvent]) {
        guard
            let threadID = state.threadID,
            let turnID = state.turnID,
            let occurredAt = state.pendingOccurredAt,
            state.pendingUsage.totalTokens > 0
        else {
            state.pendingUsage = .zero
            state.pendingOccurredAt = nil
            state.pendingRequestUsages = []
            state.pendingUnclassifiedUsage = .zero
            return
        }
        emitted.append(
            ParsedEvent(
                threadID: threadID,
                turnID: turnID,
                counterEpoch: state.counterEpoch,
                occurredAt: occurredAt,
                requestedModel: state.requestedModel,
                billedModel: state.billedModel,
                reasoningEffort: state.reasoningEffort,
                speed: state.speed,
                usage: state.pendingUsage,
                requestUsages: state.pendingRequestUsages ?? [],
                unclassifiedUsage: state.pendingRequestUsages == nil
                    ? state.pendingUsage
                    : state.pendingUnclassifiedUsage ?? .zero
            )
        )
        state.pendingUsage = .zero
        state.pendingOccurredAt = nil
        state.pendingRequestUsages = []
        state.pendingUnclassifiedUsage = .zero
    }

    private static func contextBreakdown(
        for event: ParsedEvent,
        rateCardRevisions: [OpenAIRateCardRevision]
    ) -> CodexUsageContextBreakdown {
        guard let modelID = event.billedModel ?? event.requestedModel else {
            return CodexUsageContextBreakdown(unknown: event.usage)
        }
        let revision = OpenAIRateCardPolicy.effectiveRevision(
            at: event.occurredAt,
            revisions: rateCardRevisions
        )
        var standard = CodexTokenUsage.zero
        var long = CodexTokenUsage.zero
        var unknown = event.unclassifiedUsage
        for request in event.requestUsages {
            switch OpenAIRateCardPolicy.contextTier(for: request, modelID: modelID, revision: revision) {
            case .standard: standard = standard + request
            case .long: long = long + request
            case .unknown: unknown = unknown + request
            }
        }
        let result = CodexUsageContextBreakdown(standard: standard, long: long, unknown: unknown)
        return result.total == event.usage ? result : CodexUsageContextBreakdown(unknown: event.usage)
    }

    private static func usage(from object: [String: Any]) -> CodexTokenUsage? {
        func integer(_ key: String) -> Int64 {
            if let value = object[key] as? NSNumber { return value.int64Value }
            return 0
        }
        guard object["total_tokens"] != nil else { return nil }
        return CodexTokenUsage(
            inputTokens: integer("input_tokens"),
            cachedInputTokens: integer("cached_input_tokens"),
            cacheWriteInputTokens: integer("cache_write_input_tokens"),
            outputTokens: integer("output_tokens"),
            reasoningOutputTokens: integer("reasoning_output_tokens"),
            totalTokens: integer("total_tokens")
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }
}

private struct ParserState: Codable, Sendable {
    var threadID: String?
    var turnID: String?
    var requestedModel: String?
    var billedModel: String?
    var reasoningEffort: String?
    var speed: String?
    var counterEpoch = 0
    var previousCumulative: CodexTokenUsage?
    var pendingUsage = CodexTokenUsage.zero
    var pendingOccurredAt: Date?
    var pendingRequestUsages: [CodexTokenUsage]? = []
    var pendingUnclassifiedUsage: CodexTokenUsage? = .zero
}

private struct ParsedEvent: Sendable {
    let threadID: String
    let turnID: String
    let counterEpoch: Int
    let occurredAt: Date
    let requestedModel: String?
    let billedModel: String?
    let reasoningEffort: String?
    let speed: String?
    let usage: CodexTokenUsage
    let requestUsages: [CodexTokenUsage]
    let unclassifiedUsage: CodexTokenUsage
}

private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}

public final class CodexRolloutDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.amir.Limits.CodexRolloutDirectoryWatcher")
    private let codexHome: URL
    private let roots: [URL]
    private let onChange: @Sendable () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []

    public init(codexHome: URL, onChange: @escaping @Sendable () -> Void) {
        self.codexHome = codexHome
        roots = [
            codexHome.appending(path: "sessions", directoryHint: .isDirectory),
            codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory),
        ]
        self.onChange = onChange
    }

    public func start() {
        queue.async { [weak self] in self?.rebuildSources() }
    }

    public func stop() {
        queue.sync {
            for source in sources { source.cancel() }
            sources.removeAll()
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }

    private func rebuildSources() {
        for source in sources { source.cancel() }
        sources.removeAll()
        let manager = FileManager.default
        var directories = manager.fileExists(atPath: codexHome.path) ? [codexHome] : []
        directories += roots.flatMap { root -> [URL] in
            var result: [URL] = manager.fileExists(atPath: root.path) ? [root] : []
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return result }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    result.append(url)
                }
            }
            return result
        }
        for directory in directories {
            let descriptor = Darwin.open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                onChange()
                if source.data.contains(.rename) || source.data.contains(.delete) || source.data.contains(.write) {
                    rebuildSources()
                }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }
}
