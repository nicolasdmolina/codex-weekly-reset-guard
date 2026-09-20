import Darwin
import Foundation

public enum AppServerTransportError: Error, Equatable, Sendable {
    case alreadyStarted
    case executableMustBeAbsolute
    case executableNotFound
    case codexHomeNotFound
    case processLaunchFailed
    case processExited(Int32)
    case transportClosed
    case messageTooLarge
    case writeFailed
}

/// Newline-delimited JSON transport backed by one `codex app-server` child process.
///
/// The child receives an explicit, app-owned `CODEX_HOME`. Stderr is discarded rather than
/// captured because authentication diagnostics can contain material that must never enter this
/// app's event ledger.
public actor ProcessAppServerTransport: AppServerTransport {
    public nonisolated let executableURL: URL
    public nonisolated let codexHomeURL: URL
    public nonisolated let maximumMessageBytes: Int

    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var readBuffer = Data()
    private var queuedMessages: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, any Error>] = []
    private var terminalError: (any Error)?
    private var reachedEnd = false
    private var stopping = false

    public init(
        executableURL: URL,
        codexHomeURL: URL,
        maximumMessageBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.codexHomeURL = codexHomeURL.standardizedFileURL
        self.maximumMessageBytes = maximumMessageBytes
    }

    public func start() async throws {
        guard process == nil else { throw AppServerTransportError.alreadyStarted }
        guard executableURL.path.hasPrefix("/") else {
            throw AppServerTransportError.executableMustBeAbsolute
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppServerTransportError.executableNotFound
        }

        var codexHomeIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: codexHomeURL.path,
            isDirectory: &codexHomeIsDirectory
        ), codexHomeIsDirectory.boolValue else {
            throw AppServerTransportError.codexHomeNotFound
        }

        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = codexHomeURL

        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where Self.shouldRemoveEnvironmentValue(named: key) {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = codexHomeURL.path
        environment["CODEX_SQLITE_HOME"] = codexHomeURL.path
        child.environment = environment

        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeOutput(data) }
        }
        child.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { await self?.processDidTerminate(status: status) }
        }

        do {
            try child.run()
        } catch {
            outputHandle.readabilityHandler = nil
            child.terminationHandler = nil
            throw AppServerTransportError.processLaunchFailed
        }

        process = child
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputHandle
        readBuffer.removeAll(keepingCapacity: true)
        queuedMessages.removeAll(keepingCapacity: true)
        terminalError = nil
        reachedEnd = false
        stopping = false
    }

    public func send(_ message: Data) async throws {
        guard let process, process.isRunning, let standardInput, !reachedEnd else {
            throw AppServerTransportError.transportClosed
        }
        guard message.count <= maximumMessageBytes else {
            throw AppServerTransportError.messageTooLarge
        }

        var framed = message
        if framed.last != 0x0A { framed.append(0x0A) }
        do {
            try standardInput.write(contentsOf: framed)
        } catch {
            throw AppServerTransportError.writeFailed
        }
    }

    public func receive() async throws -> Data? {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        if let terminalError { throw terminalError }
        if reachedEnd { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    public func stop() async {
        guard process != nil || !reachedEnd else { return }
        stopping = true
        standardOutput?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? standardInput?.close()

        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        process = nil
        standardInput = nil
        standardOutput = nil
        finish(with: nil)
    }

    private func consumeOutput(_ data: Data) {
        guard !reachedEnd else { return }
        guard !data.isEmpty else {
            finish(with: stopping ? nil : AppServerTransportError.transportClosed)
            return
        }

        readBuffer.append(data)
        let newline = Data([0x0A])
        while let range = readBuffer.range(of: newline) {
            guard range.lowerBound <= maximumMessageBytes else {
                process?.terminate()
                finish(with: AppServerTransportError.messageTooLarge)
                return
            }
            var line = readBuffer.subdata(in: readBuffer.startIndex..<range.lowerBound)
            readBuffer.removeSubrange(readBuffer.startIndex...range.lowerBound)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { emit(line) }
        }
        guard readBuffer.count <= maximumMessageBytes else {
            process?.terminate()
            finish(with: AppServerTransportError.messageTooLarge)
            return
        }
    }

    private func processDidTerminate(status: Int32) {
        let error: (any Error)? = stopping || status == 0
            ? nil
            : AppServerTransportError.processExited(status)
        process = nil
        standardInput = nil
        standardOutput?.readabilityHandler = nil
        standardOutput = nil
        finish(with: error)
    }

    private func emit(_ message: Data) {
        if receiveWaiters.isEmpty {
            queuedMessages.append(message)
        } else {
            receiveWaiters.removeFirst().resume(returning: message)
        }
    }

    private func finish(with error: (any Error)?) {
        guard !reachedEnd else { return }
        reachedEnd = true
        terminalError = error
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    private nonisolated static func shouldRemoveEnvironmentValue(named key: String) -> Bool {
        let normalized = key.uppercased()
        return normalized == "CODEX_HOME"
            || normalized == "CODEX_SQLITE_HOME"
            || normalized == "OPENAI_API_KEY"
            || normalized == "CODEX_API_KEY"
            || normalized == "CHATGPT_ACCESS_TOKEN"
            || normalized.hasSuffix("_OPENAI_API_KEY")
    }
}

public enum AppServerClientError: Error, Equatable, Sendable {
    case shutDown
    case invalidTimeout
    case transportClosed
    case transportFailure
    case timedOut(method: String)
    case invalidMessage
    case unexpectedResponse(method: String)
    case rpc(code: Int, message: String)
    case codexHomeMismatch
    case invalidLoginResponse

    fileprivate var isRetryableTransportFailure: Bool {
        switch self {
        case .transportClosed, .transportFailure, .timedOut:
            true
        default:
            false
        }
    }
}

public actor AppServerClient {
    public enum ConnectionState: String, Equatable, Sendable {
        case disconnected
        case starting
        case ready
        case stopped
    }

    private enum RetryDisposition {
        case never
        case safe
    }

    public nonisolated let profileID: UUID

    private let transportFactory: AppServerTransportFactory
    private let expectedCodexHomeURL: URL?
    private let requestTimeout: Duration
    private let restartDelays: [Duration]
    private let eventLog: RedactedEventLog?
    private let requestGate = AppServerRequestGate()
    private let clientInfo: RPCInitializeParams.ClientInfo

    private var state: ConnectionState = .disconnected
    private var isShutDown = false
    private var transport: (any AppServerTransport)?
    private var connectionGeneration: UUID?
    private var readerTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var pendingResponses: [Int64: PendingResponse] = [:]
    private var notificationContinuations: [UUID: AsyncStream<AppServerNotification>.Continuation] = [:]

    public init(
        profileID: UUID,
        transportFactory: @escaping AppServerTransportFactory,
        requestTimeout: Duration = .seconds(15),
        restartDelays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2)],
        eventLog: RedactedEventLog? = nil,
        clientVersion: String = "1.0.0"
    ) {
        self.profileID = profileID
        self.transportFactory = transportFactory
        self.expectedCodexHomeURL = nil
        self.requestTimeout = requestTimeout
        self.restartDelays = restartDelays
        self.eventLog = eventLog
        self.clientInfo = .init(
            name: "codex_weekly_reset_guard",
            title: "Codex Weekly Reset Guard",
            version: clientVersion
        )
    }

    public init(
        profile: ProfileConfiguration,
        codexExecutableURL: URL,
        profilesDirectory: URL = ProfileConfiguration.defaultProfilesDirectory,
        requestTimeout: Duration = .seconds(15),
        restartDelays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2)],
        eventLog: RedactedEventLog? = nil,
        clientVersion: String = "1.0.0"
    ) throws {
        let codexHomeURL = try profile.prepareCodexHome(profilesDirectory: profilesDirectory)
        self.profileID = profile.id
        self.expectedCodexHomeURL = codexHomeURL
        self.transportFactory = {
            ProcessAppServerTransport(
                executableURL: codexExecutableURL,
                codexHomeURL: codexHomeURL
            )
        }
        self.requestTimeout = requestTimeout
        self.restartDelays = restartDelays
        self.eventLog = eventLog
        self.clientInfo = .init(
            name: "codex_weekly_reset_guard",
            title: "Codex Weekly Reset Guard",
            version: clientVersion
        )
    }

    public func connectionState() -> ConnectionState {
        state
    }

    public func notifications() -> AsyncStream<AppServerNotification> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AppServerNotification.self,
            bufferingPolicy: .bufferingNewest(50)
        )
        notificationContinuations[subscriptionID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNotificationContinuation(subscriptionID) }
        }
        return stream
    }

    public func start() async throws {
        await requestGate.acquire()
        do {
            try await ensureConnectedLocked()
            await requestGate.release()
        } catch {
            await requestGate.release()
            throw error
        }
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await disconnectLocked(finalState: .stopped)
        for continuation in notificationContinuations.values {
            continuation.finish()
        }
        notificationContinuations.removeAll()
    }

    public func accountRead(refreshToken: Bool = false) async throws -> RPCAccountReadResponse {
        struct Params: Encodable { let refreshToken: Bool }
        return try await perform(
            method: .accountRead,
            params: try RPCJSONValue.encoding(Params(refreshToken: refreshToken)),
            retry: .safe
        )
    }

    public func startChatGPTLogin(
        useHostedLoginSuccessPage: Bool = true,
        appBrand: String = "chatgpt"
    ) async throws -> RPCChatGPTLoginStartResponse {
        struct Params: Encodable {
            let type = "chatgpt"
            let useHostedLoginSuccessPage: Bool
            let appBrand: String
        }

        guard appBrand == "chatgpt" || appBrand == "codex" else {
            throw AppServerClientError.invalidLoginResponse
        }

        let response: RPCChatGPTLoginStartResponse = try await perform(
            method: .accountLoginStart,
            params: try RPCJSONValue.encoding(
                Params(
                    useHostedLoginSuccessPage: useHostedLoginSuccessPage,
                    appBrand: appBrand
                )
            ),
            retry: .never
        )
        guard response.type == "chatgpt",
              !response.loginID.isEmpty,
              response.authURL.scheme?.lowercased() == "https",
              response.authURL.host != nil else {
            throw AppServerClientError.invalidLoginResponse
        }
        return response
    }

    public func readRateLimits() async throws -> RPCRateLimitsReadResponse {
        try await perform(method: .accountRateLimitsRead, params: nil, retry: .safe)
    }

    public func consumeReset(
        idempotencyKey: String,
        creditID: String? = nil
    ) async throws -> RPCConsumeResetOutcome {
        struct Params: Encodable {
            let idempotencyKey: String
            let creditID: String?

            enum CodingKeys: String, CodingKey {
                case idempotencyKey
                case creditID = "creditId"
            }
        }

        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              creditID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw AppServerClientError.unexpectedResponse(
                method: AppServerMethod.accountRateLimitResetCreditConsume.rawValue
            )
        }

        let response: RPCConsumeResetResponse = try await perform(
            method: .accountRateLimitResetCreditConsume,
            params: try RPCJSONValue.encoding(
                Params(idempotencyKey: idempotencyKey, creditID: creditID)
            ),
            retry: .safe
        )
        return response.outcome
    }

    private func perform<Response: Decodable>(
        method: AppServerMethod,
        params: RPCJSONValue?,
        retry: RetryDisposition
    ) async throws -> Response {
        await requestGate.acquire()
        do {
            let value = try await performLocked(method: method, params: params, retry: retry)
            let response: Response
            do {
                response = try value.decode(Response.self)
            } catch {
                throw AppServerClientError.unexpectedResponse(method: method.rawValue)
            }
            await requestGate.release()
            return response
        } catch {
            await requestGate.release()
            throw error
        }
    }

    private func performLocked(
        method: AppServerMethod,
        params: RPCJSONValue?,
        retry: RetryDisposition
    ) async throws -> RPCJSONValue {
        var retryIndex = 0
        while true {
            try await ensureConnectedLocked()
            do {
                return try await sendRequestLocked(method: method, params: params)
            } catch let error as AppServerClientError {
                guard retry == .safe,
                      error.isRetryableTransportFailure,
                      retryIndex < restartDelays.count else {
                    throw error
                }
                await disconnectLocked(finalState: .disconnected)
                let delay = restartDelays[retryIndex]
                retryIndex += 1
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func ensureConnectedLocked() async throws {
        guard !isShutDown else { throw AppServerClientError.shutDown }
        if state == .ready, transport != nil { return }

        var lastError: AppServerClientError = .transportFailure
        for attempt in 0...restartDelays.count {
            guard !isShutDown else { throw AppServerClientError.shutDown }
            do {
                try await establishConnectionLocked()
                return
            } catch let error as AppServerClientError {
                lastError = error
            } catch {
                lastError = .transportFailure
            }

            await disconnectLocked(finalState: isShutDown ? .stopped : .disconnected)
            guard !isShutDown else { throw AppServerClientError.shutDown }
            guard lastError.isRetryableTransportFailure else { throw lastError }
            if attempt < restartDelays.count {
                try? await Task.sleep(for: restartDelays[attempt])
            }
        }
        throw lastError
    }

    private func establishConnectionLocked() async throws {
        guard !isShutDown else { throw AppServerClientError.shutDown }
        guard requestTimeout > .zero else { throw AppServerClientError.invalidTimeout }

        state = .starting
        let newTransport = transportFactory()
        do {
            try await newTransport.start()
        } catch {
            throw AppServerClientError.transportFailure
        }
        if isShutDown {
            await newTransport.stop()
            throw AppServerClientError.shutDown
        }

        let generation = UUID()
        transport = newTransport
        connectionGeneration = generation
        readerTask = Task { [weak self, newTransport] in
            do {
                while let message = try await newTransport.receive() {
                    guard !Task.isCancelled else { return }
                    await self?.handleIncoming(message, generation: generation)
                }
                await self?.connectionEnded(generation: generation, error: .transportClosed)
            } catch {
                await self?.connectionEnded(generation: generation, error: .transportFailure)
            }
        }

        let initializeParams = RPCInitializeParams(clientInfo: clientInfo)
        let value = try await sendRequestLocked(
            method: .initialize,
            params: try RPCJSONValue.encoding(initializeParams)
        )
        let response: RPCInitializeResponse
        do {
            response = try value.decode(RPCInitializeResponse.self)
        } catch {
            throw AppServerClientError.unexpectedResponse(method: AppServerMethod.initialize.rawValue)
        }

        if let expectedCodexHomeURL {
            let actual = URL(fileURLWithPath: response.codexHome)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let expected = expectedCodexHomeURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard actual == expected else { throw AppServerClientError.codexHomeMismatch }
        }

        let initialized = AppServerNotificationEnvelope(
            method: AppServerMethod.initialized.rawValue,
            params: .object([:])
        )
        do {
            try await newTransport.send(try JSONEncoder().encode(initialized))
        } catch {
            throw AppServerClientError.transportFailure
        }
        guard generation == connectionGeneration, transport != nil, !isShutDown else {
            throw AppServerClientError.transportClosed
        }
        state = .ready
        if let eventLog {
            _ = try? await eventLog.append(profileID: profileID, kind: .profileConnected)
        }
    }

    private func sendRequestLocked(
        method: AppServerMethod,
        params: RPCJSONValue?
    ) async throws -> RPCJSONValue {
        guard let transport else { throw AppServerClientError.transportClosed }
        guard requestTimeout > .zero else { throw AppServerClientError.invalidTimeout }

        let requestID = nextRequestID
        nextRequestID = nextRequestID == Int64.max ? 1 : nextRequestID + 1
        let envelope = AppServerRequestEnvelope(
            id: requestID,
            method: method.rawValue,
            params: params
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw AppServerClientError.invalidMessage
        }

        let response = RPCResponseWaiter()
        pendingResponses[requestID] = PendingResponse(method: method.rawValue, waiter: response)
        do {
            try await transport.send(data)
        } catch {
            pendingResponses.removeValue(forKey: requestID)
            throw AppServerClientError.transportFailure
        }

        let timeoutTask = Task { [weak self, requestTimeout] in
            do {
                try await Task.sleep(for: requestTimeout)
            } catch {
                return
            }
            await self?.requestTimedOut(requestID: requestID)
        }
        defer { timeoutTask.cancel() }
        return try await response.wait()
    }

    private func handleIncoming(_ data: Data, generation: UUID) async {
        guard generation == connectionGeneration else { return }
        let envelope: AppServerResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(AppServerResponseEnvelope.self, from: data)
        } catch {
            await connectionEnded(generation: generation, error: .invalidMessage)
            return
        }

        if let requestID = envelope.id,
           let pending = pendingResponses.removeValue(forKey: requestID) {
            if let error = envelope.error {
                await pending.waiter.resolve(
                    .failure(
                        AppServerClientError.rpc(
                            code: error.code,
                            message: RedactedEventLog.redact(error.message)
                        )
                    )
                )
            } else if let result = envelope.result {
                await pending.waiter.resolve(.success(result))
            } else {
                await pending.waiter.resolve(
                    .failure(AppServerClientError.unexpectedResponse(method: pending.method))
                )
            }
            return
        }

        guard let method = envelope.method else { return }
        let notification: AppServerNotification
        switch method {
        case "account/login/completed":
            guard let params = envelope.params,
                  var value = try? params.decode(RPCLoginCompletedNotification.self) else {
                notification = .unhandled(method: method)
                break
            }
            if let error = value.error {
                value = RPCLoginCompletedNotification(
                    loginID: value.loginID,
                    success: value.success,
                    error: RedactedEventLog.redact(error)
                )
            }
            notification = .loginCompleted(value)
        case "account/updated":
            guard let params = envelope.params,
                  let value = try? params.decode(RPCAccountUpdatedNotification.self) else {
                notification = .unhandled(method: method)
                break
            }
            notification = .accountUpdated(value)
        case "account/rateLimits/updated":
            struct Params: Decodable { let rateLimits: RPCRateLimitSnapshot }
            guard let params = envelope.params,
                  let value = try? params.decode(Params.self) else {
                notification = .unhandled(method: method)
                break
            }
            notification = .rateLimitsUpdated(value.rateLimits)
        default:
            notification = .unhandled(method: method)
        }
        for continuation in notificationContinuations.values {
            continuation.yield(notification)
        }
    }

    private func requestTimedOut(requestID: Int64) async {
        guard let pending = pendingResponses.removeValue(forKey: requestID) else { return }
        await pending.waiter.resolve(
            .failure(AppServerClientError.timedOut(method: pending.method))
        )
    }

    private func connectionEnded(
        generation: UUID,
        error: AppServerClientError
    ) async {
        guard generation == connectionGeneration else { return }
        let currentTransport = transport
        transport = nil
        connectionGeneration = nil
        readerTask = nil
        if !isShutDown { state = .disconnected }
        await failAllPending(with: error)
        await currentTransport?.stop()
        if let eventLog, !isShutDown {
            _ = try? await eventLog.append(profileID: profileID, kind: .profileDisconnected)
        }
    }

    private func disconnectLocked(finalState: ConnectionState) async {
        let currentTransport = transport
        transport = nil
        connectionGeneration = nil
        readerTask?.cancel()
        readerTask = nil
        await failAllPending(with: .transportClosed)
        await currentTransport?.stop()
        state = finalState
    }

    private func failAllPending(with error: AppServerClientError) async {
        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for response in pending {
            await response.waiter.resolve(.failure(error))
        }
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }
}

private struct PendingResponse: Sendable {
    let method: String
    let waiter: RPCResponseWaiter
}

private actor RPCResponseWaiter {
    private var result: Result<RPCJSONValue, any Error>?
    private var continuation: CheckedContinuation<RPCJSONValue, any Error>?

    func wait() async throws -> RPCJSONValue {
        if let result {
            self.result = nil
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result<RPCJSONValue, any Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            self.result = result
        }
    }
}

private actor AppServerRequestGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
