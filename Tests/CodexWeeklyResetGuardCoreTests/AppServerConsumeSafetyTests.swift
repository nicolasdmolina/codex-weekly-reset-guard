import Foundation
import Testing
@testable import CodexWeeklyResetGuardCore

@Test func consumeTransportFailureDoesNotRetryInsideClient() async throws {
    let ledger = ConsumeSendLedger()
    let client = AppServerClient(
        profileID: UUID(),
        transportFactory: { ConsumeSafetyTransport(ledger: ledger, failSend: true) },
        requestTimeout: .seconds(1),
        restartDelays: [.zero]
    )
    try await client.start()
    do {
        _ = try await client.consumeReset(idempotencyKey: "one-logical-attempt")
        Issue.record("Expected the synthetic transport to fail")
    } catch let error as AppServerClientError {
        #expect(error == .transportFailure)
    }
    #expect(await ledger.count == 1)
    await client.shutdown()
}

@Test func shutdownAfterConsumeSendPreservesTransportAmbiguity() async throws {
    let ledger = ConsumeSendLedger()
    let client = AppServerClient(
        profileID: UUID(),
        transportFactory: { ConsumeSafetyTransport(ledger: ledger, failSend: false) },
        requestTimeout: .seconds(2),
        restartDelays: [.zero]
    )
    try await client.start()
    let request = Task { try await client.consumeReset(idempotencyKey: "uncertain-attempt") }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await ledger.count == 0, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await ledger.count == 1)
    await client.shutdown()
    do {
        _ = try await request.value
        Issue.record("Expected shutdown to interrupt the pending reply")
    } catch let error as AppServerClientError {
        #expect(error == .transportClosed)
    }
    #expect(await ledger.count == 1)
}

private actor ConsumeSendLedger {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ConsumeSafetyTransport: AppServerTransport {
    let ledger: ConsumeSendLedger
    let failSend: Bool
    private var stopped = false
    private var queue: [Data] = []
    private var waiters: [CheckedContinuation<Data?, any Error>] = []

    init(ledger: ConsumeSendLedger, failSend: Bool) {
        self.ledger = ledger
        self.failSend = failSend
    }

    func start() async throws {}

    func send(_ message: Data) async throws {
        guard !stopped else { throw AppServerTransportError.transportClosed }
        let object = try JSONSerialization.jsonObject(with: message) as? [String: Any]
        let method = object?["method"] as? String
        if method == "initialize" {
            let id = (object?["id"] as? NSNumber)?.int64Value ?? 0
            emit(Data("{\"id\":\(id),\"result\":{\"userAgent\":\"fixture\",\"platformFamily\":\"unix\",\"platformOs\":\"macos\",\"codexHome\":\"/fixture\"}}".utf8))
        } else if method == "account/rateLimitResetCredit/consume" {
            await ledger.record()
            if failSend { throw AppServerTransportError.writeFailed }
        }
    }

    func receive() async throws -> Data? {
        if !queue.isEmpty { return queue.removeFirst() }
        if stopped { return nil }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func stop() async {
        stopped = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    private func emit(_ data: Data) {
        if waiters.isEmpty { queue.append(data) }
        else { waiters.removeFirst().resume(returning: data) }
    }
}
