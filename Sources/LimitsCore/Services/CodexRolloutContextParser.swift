import Foundation

/// Extracts only observable work identity from a local Codex rollout.
/// Project identity comes from git/cwd metadata and task identity comes from
/// the first user message; this parser never guesses semantic categories.
enum CodexRolloutContextParser {
    static func parse(file: URL) throws -> [CodexRolloutContext] {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        var currentThreadID: String?
        var currentProject: ProjectReference?
        var taskTitles: [String: String] = [:]
        var contexts: [String: CodexRolloutContext] = [:]

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let envelope = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = envelope["type"] as? String,
                  let payload = envelope["payload"] as? [String: Any] else { continue }
            let timestamp = (envelope["timestamp"] as? String).flatMap(parseDate) ?? .distantPast

            switch type {
            case "session_meta":
                guard let threadID = (payload["session_id"] as? String) ?? (payload["id"] as? String) else { continue }
                currentThreadID = threadID
                currentProject = projectReference(from: payload) ?? currentProject
                mergeContext(
                    threadID: threadID,
                    turnID: nil,
                    project: currentProject,
                    taskTitle: taskTitles[threadID],
                    observedAt: timestamp,
                    into: &contexts
                )
            case "turn_context":
                guard let threadID = currentThreadID,
                      let turnID = payload["turn_id"] as? String else { continue }
                if let candidate = projectReference(from: payload),
                   currentProject?.source != .git || candidate.source == .git {
                    currentProject = candidate
                }
                mergeContext(
                    threadID: threadID,
                    turnID: turnID,
                    project: currentProject,
                    taskTitle: taskTitles[threadID],
                    observedAt: timestamp,
                    into: &contexts
                )
            case "event_msg":
                guard (payload["type"] as? String) == "user_message",
                      let threadID = currentThreadID,
                      taskTitles[threadID] == nil,
                      let message = payload["message"] as? String,
                      let title = taskTitle(from: message) else { continue }
                taskTitles[threadID] = title
                mergeTaskTitle(title, threadID: threadID, into: &contexts)
            case "response_item":
                guard (payload["type"] as? String) == "message",
                      (payload["role"] as? String) == "user",
                      let threadID = currentThreadID,
                      taskTitles[threadID] == nil,
                      let title = taskTitle(from: messageText(in: payload)) else { continue }
                taskTitles[threadID] = title
                mergeTaskTitle(title, threadID: threadID, into: &contexts)
            default:
                continue
            }
        }
        return contexts.values.sorted { $0.id < $1.id }
    }

    private struct ProjectReference {
        enum Source { case git, cwd }
        let id: String
        let title: String
        let source: Source
    }

    private static func projectReference(from payload: [String: Any]) -> ProjectReference? {
        if let git = payload["git"] as? [String: Any],
           let repository = git["repository_url"] as? String,
           !repository.isEmpty {
            let component = repository.split(separator: "/").last.map(String.init) ?? repository
            return ProjectReference(
                id: repository,
                title: component.replacingOccurrences(of: ".git", with: ""),
                source: .git
            )
        }
        guard let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        let url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return ProjectReference(id: url.path, title: title, source: .cwd)
    }

    private static func messageText(in payload: [String: Any]) -> String {
        guard let content = payload["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { item in
            guard (item["type"] as? String) == "input_text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }

    private static func taskTitle(from message: String) -> String? {
        let relevant = message.components(separatedBy: "## My request:").last ?? message
        guard let line = relevant.split(whereSeparator: \Character.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("<image") })
        else { return nil }
        let markdownTrimmed = line.drop(while: { "#>*- \"".contains($0) })
        let title = String(markdownTrimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return title.count <= 96 ? title : String(title.prefix(95)) + "…"
    }

    private static func mergeContext(
        threadID: String,
        turnID: String?,
        project: ProjectReference?,
        taskTitle: String?,
        observedAt: Date,
        into contexts: inout [String: CodexRolloutContext]
    ) {
        let id = "\(threadID)|\(turnID ?? "")"
        let existing = contexts[id]
        contexts[id] = CodexRolloutContext(
            threadID: threadID,
            turnID: turnID,
            projectID: project?.id ?? existing?.projectID,
            projectTitle: project?.title ?? existing?.projectTitle,
            taskTitle: taskTitle ?? existing?.taskTitle,
            observedAt: max(observedAt, existing?.observedAt ?? .distantPast)
        )
    }

    private static func mergeTaskTitle(
        _ title: String,
        threadID: String,
        into contexts: inout [String: CodexRolloutContext]
    ) {
        for (id, context) in contexts where context.threadID == threadID {
            contexts[id] = CodexRolloutContext(
                threadID: context.threadID,
                turnID: context.turnID,
                projectID: context.projectID,
                projectTitle: context.projectTitle,
                taskTitle: title,
                observedAt: context.observedAt
            )
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }
}
