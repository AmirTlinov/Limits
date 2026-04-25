import Foundation

enum CodexAppServerTransportError: LocalizedError {
    case invalidEnvelope
    case missingResponse
    case requestTimedOut(String)
    case loginTimedOut
    case processExited(String)
    case loginRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Codex app-server returned an invalid JSON-RPC envelope."
        case .missingResponse:
            return "Codex app-server did not return a usable response."
        case .requestTimedOut(let method):
            return "Codex app-server request timed out: \(method)."
        case .loginTimedOut:
            return "The Codex login flow timed out."
        case .processExited(let detail):
            return "Codex app-server exited unexpectedly. \(detail)"
        case .loginRejected(let detail):
            return detail
        }
    }
}

final class CodexAppServerTransport: @unchecked Sendable {
    private struct LoginWaiter {
        let loginId: String
        let resolve: (Result<AppServerLoginCompletedNotification, Error>) -> Void
    }

    private let process = Process()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let queue = DispatchQueue(label: "com.amir.Limits.CodexAppServerTransport")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1

    private var buffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [Int: (Result<Data, Error>) -> Void] = [:]
    private var loginWaiters: [UUID: LoginWaiter] = [:]
    private var stderrLines: [String] = []
    private var isClosed = false

    init(executableURL: URL, codexHome: URL, environment: [String: String]) throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var processEnvironment = environment
        processEnvironment["CODEX_HOME"] = codexHome.path
        process.environment = processEnvironment

        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        queue.setSpecific(key: queueKey, value: queueValue)

        try process.run()
        configureIO()
    }

    deinit {
        close()
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "limits",
                    "version": "0.1.0",
                ],
                "capabilities": [:],
            ],
            responseType: AppServerInitializeResponse.self
        )
        try await notify(method: "initialized", params: nil)
    }

    func startChatGPTLogin() async throws -> AppServerLoginResponse {
        try await request(
            method: "account/login/start",
            params: ["type": "chatgpt"],
            responseType: AppServerLoginResponse.self
        )
    }

    func cancelLogin(loginId: String) async throws {
        _ = try await request(
            method: "account/login/cancel",
            params: ["loginId": loginId],
            responseType: AppServerCancelLoginResponse.self
        )
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerGetAccountResponse {
        try await request(
            method: "account/read",
            params: ["refreshToken": refreshToken],
            responseType: AppServerGetAccountResponse.self
        )
    }

    func readRateLimits() async throws -> AppServerRateLimitsResponse {
        try await request(
            method: "account/rateLimits/read",
            params: nil,
            responseType: AppServerRateLimitsResponse.self
        )
    }

    func waitForLoginCompletion(loginId: String, timeout: TimeInterval = 300) async throws -> AppServerLoginCompletedNotification {
        try await withCheckedThrowingContinuation { continuation in
            let waiterID = UUID()

            queue.async {
                self.loginWaiters[waiterID] = LoginWaiter(loginId: loginId) { result in
                    continuation.resume(with: result)
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                guard let waiter = self.loginWaiters.removeValue(forKey: waiterID) else {
                    return
                }
                waiter.resolve(.failure(CodexAppServerTransportError.loginTimedOut))
            }
        }
    }

    func close() {
        let shouldTerminate: Bool
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            shouldTerminate = closeLocked()
        } else {
            shouldTerminate = queue.sync {
                closeLocked()
            }
        }

        if shouldTerminate {
            process.terminate()
        }
    }

    private func configureIO() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }

            let data = handle.availableData
            guard !data.isEmpty else {
                self.handleEOF()
                return
            }

            self.queue.async { [self] in
                buffer.append(data)
                drainBufferedLines()
            }
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }

            let data = handle.availableData
            guard
                !data.isEmpty,
                let string = String(data: data, encoding: .utf8)
            else { return }

            self.queue.async { [self] in
                stderrLines.append(string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.handleEOF()
        }
    }

    @discardableResult
    private func closeLocked() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        let error = CodexAppServerTransportError.processExited(stderrLines.joined(separator: "\n"))
        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for resolver in pending {
            resolver(.failure(error))
        }

        let waiters = loginWaiters.values
        loginWaiters.removeAll()
        for waiter in waiters {
            waiter.resolve(.failure(error))
        }

        return process.isRunning
    }

    private func handleEOF() {
        queue.async {
            guard !self.isClosed else { return }
            self.close()
        }
    }

    private func drainBufferedLines() {
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard !lineData.isEmpty else {
                continue
            }

            do {
                try handleLineData(lineData)
            } catch {
                stderrLines.append(error.localizedDescription)
            }
        }
    }

    private func handleLineData(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerTransportError.invalidEnvelope
        }

        if let id = object["id"] as? Int {
            if object["method"] != nil {
                try handleServerRequest(id: id, object: object)
                return
            }

            let resolver = pendingResponses.removeValue(forKey: id)
            guard let resolver else { return }

            if let errorObject = object["error"] as? [String: Any] {
                let payload = try JSONSerialization.data(withJSONObject: errorObject, options: [])
                let serverError = try? JSONDecoder.limits.decode(JSONRPCServerError.self, from: payload)
                resolver(.failure(serverError ?? CodexAppServerTransportError.missingResponse))
                return
            }

            guard let resultObject = object["result"] else {
                resolver(.failure(CodexAppServerTransportError.missingResponse))
                return
            }

            let payload = try JSONSerialization.data(withJSONObject: resultObject, options: [])
            resolver(.success(payload))
            return
        }

        guard let method = object["method"] as? String else {
            throw CodexAppServerTransportError.invalidEnvelope
        }

        let paramsData: Data?
        if let params = object["params"] {
            paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
        } else {
            paramsData = nil
        }
        handleNotification(method: method, paramsData: paramsData)
    }

    private func handleNotification(method: String, paramsData: Data?) {
        guard method == "account/login/completed", let paramsData else {
            return
        }

        guard let notification = try? JSONDecoder.limits.decode(AppServerLoginCompletedNotification.self, from: paramsData) else {
            return
        }

        let matching = loginWaiters.first { _, waiter in
            waiter.loginId == notification.loginId
        }

        guard let matching else { return }
        loginWaiters.removeValue(forKey: matching.key)

        if notification.success {
            matching.value.resolve(.success(notification))
        } else {
            let message = notification.error ?? "Codex login did not complete."
            matching.value.resolve(.failure(CodexAppServerTransportError.loginRejected(message)))
        }
    }

    private func handleServerRequest(id: Int, object: [String: Any]) throws {
        let method = object["method"] as? String ?? "unknown"
        let errorPayload: [String: Any] = [
            "id": id,
            "error": [
                "code": -32601,
                "message": "Unsupported server request: \(method)",
            ],
        ]
        try sendEnvelope(errorPayload)
    }

    private func notify(method: String, params: Any?) async throws {
        let paramsData = try encodeParams(params)

        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.sendEnvelope(method: method, paramsData: paramsData)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func request<Response: Decodable>(method: String, params: Any?, responseType: Response.Type) async throws -> Response {
        let paramsData = try encodeParams(params)

        let data = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let requestID = self.nextRequestID
                self.nextRequestID += 1

                self.pendingResponses[requestID] = { result in
                    continuation.resume(with: result)
                }

                self.queue.asyncAfter(deadline: .now() + 30) {
                    guard let resolver = self.pendingResponses.removeValue(forKey: requestID) else {
                        return
                    }
                    resolver(.failure(CodexAppServerTransportError.requestTimedOut(method)))
                }

                do {
                    try self.sendEnvelope(id: requestID, method: method, paramsData: paramsData)
                } catch {
                    let resolver = self.pendingResponses.removeValue(forKey: requestID)
                    resolver?(.failure(error))
                }
            }
        }

        return try JSONDecoder.limits.decode(Response.self, from: data)
    }

    private func encodeParams(_ params: Any?) throws -> Data? {
        guard let params else { return nil }
        return try JSONSerialization.data(withJSONObject: params, options: [])
    }

    private func sendEnvelope(id: Int? = nil, method: String, paramsData: Data?) throws {
        var object: [String: Any] = ["method": method]
        if let id {
            object["id"] = id
        }
        if let paramsData {
            object["params"] = try JSONSerialization.jsonObject(with: paramsData)
        }
        try sendEnvelope(object)
    }

    private func sendEnvelope(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        stdinHandle.write(data)
        stdinHandle.write(Data([0x0A]))
    }
}
