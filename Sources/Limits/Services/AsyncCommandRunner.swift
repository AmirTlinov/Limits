import Darwin
import Foundation

enum AsyncCommandRunnerError: LocalizedError, Equatable {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            return L10n.tr("process.timeout", timeout.formatted(.number.precision(.fractionLength(0...1))))
        }
    }
}

struct AsyncCommandResult: Sendable, Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

struct AsyncCommandRunner: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> AsyncCommandResult {
        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appending(path: "limits-command-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appending(path: "stdout")
        let stderrURL = captureDirectory.appending(path: "stderr")
        guard
            fileManager.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
            fileManager.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        let signal = ProcessTerminationSignal()
        let running = RunningProcess(process)
        process.terminationHandler = { process in
            signal.finish(process.terminationStatus)
        }

        try process.run()

        let status = try await withTaskCancellationHandler {
            try await waitForTermination(of: running, signal: signal, timeout: timeout)
        } onCancel: {
            running.stop()
        }

        try stdout.close()
        try stderr.close()
        return AsyncCommandResult(
            terminationStatus: status,
            standardOutput: try Data(contentsOf: stdoutURL),
            standardError: try Data(contentsOf: stderrURL)
        )
    }

    private func waitForTermination(
        of process: RunningProcess,
        signal: ProcessTerminationSignal,
        timeout: TimeInterval
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await signal.value()
            }
            group.addTask {
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                process.stop()
                throw AsyncCommandRunnerError.timedOut(timeout)
            }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }
}

private final class ProcessTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func finish(_ status: Int32) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            guard self.status == nil else { return [] }
            self.status = status
            defer { self.waiters.removeAll() }
            return self.waiters
        }
        waiters.forEach { $0.resume(returning: status) }
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            let knownStatus = lock.withLock { () -> Int32? in
                if let status {
                    return status
                }
                waiters.append(continuation)
                return nil
            }
            if let knownStatus {
                continuation.resume(returning: knownStatus)
            }
        }
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopRequested = false

    init(_ process: Process) {
        self.process = process
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopRequested else { return false }
            stopRequested = true
            return true
        }
        guard shouldStop, process.isRunning else { return }

        process.terminate()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }
}
