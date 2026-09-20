import Foundation
import Testing
@testable import CodexWeeklyResetGuardCore

@Test func decodesCurrentRateLimitAndResetCreditFixture() throws {
    let fixture = #"""
    {
      "rateLimits": {
        "limitId": "codex",
        "limitName": null,
        "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1785250000 },
        "secondary": { "usedPercent": 97, "windowDurationMins": 10080, "resetsAt": 1785850000 },
        "rateLimitReachedType": "rate_limit_reached"
      },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex",
          "limitName": null,
          "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1785250000 },
          "secondary": { "usedPercent": 97, "windowDurationMins": 10080, "resetsAt": 1785850000 }
        },
        "codex_spark": {
          "limitId": "codex_spark",
          "limitName": "Codex Spark Weekly",
          "primary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 1785850000 },
          "secondary": null
        }
      },
      "rateLimitResetCredits": {
        "availableCount": 2,
        "credits": [{
          "id": "RateLimitResetCredit_1",
          "resetType": "codexRateLimits",
          "status": "available",
          "grantedAt": 1781654400,
          "expiresAt": 1784246400,
          "title": "Rate-limit reset",
          "description": "Reset an eligible Codex rate-limit window."
        }]
      }
    }
    """#

    let response = try JSONDecoder().decode(
        RPCRateLimitsReadResponse.self,
        from: Data(fixture.utf8)
    )

    let canonical = try #require(response.canonicalCodexRateLimits)
    #expect(canonical.limitID == "codex")
    #expect(canonical.primary?.windowDurationMinutes == 300)
    #expect(canonical.secondary?.windowDurationMinutes == 10_080)
    #expect(response.rateLimitsByLimitID?["codex_spark"]?.limitName == "Codex Spark Weekly")
    #expect(response.rateLimitResetCredits?.availableCount == 2)
    #expect(response.rateLimitResetCredits?.credits?.first?.resetType == "codexRateLimits")

    let observedAt = Date(timeIntervalSince1970: 1_785_000_000)
    let domain = canonical.domainValue(observedAt: observedAt)
    #expect(domain.observedAt == observedAt)
    #expect(domain.secondary?.windowDurationMinutes == 10_080)
    #expect(domain.secondary?.resetsAt == Date(timeIntervalSince1970: 1_785_850_000))

    let inventory = response.rateLimitResetCredits?.domainValue()
    #expect(inventory?.availableCount == 2)
    #expect(inventory?.credits?.first?.kind == .codexRateLimits)
    #expect(inventory?.credits?.first?.status == .available)
}

@Test func encodesStableWireMethodsWithoutJSONRPCHeader() throws {
    struct ConsumeParams: Encodable {
        let idempotencyKey: String
        let creditId: String
    }

    let envelope = AppServerRequestEnvelope(
        id: 8,
        method: AppServerMethod.accountRateLimitResetCreditConsume.rawValue,
        params: try RPCJSONValue.encoding(
            ConsumeParams(idempotencyKey: "attempt-1", creditId: "opaque-credit")
        )
    )
    let data = try JSONEncoder().encode(envelope)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let params = try #require(object["params"] as? [String: Any])

    #expect(object["jsonrpc"] == nil)
    #expect(object["id"] as? Int == 8)
    #expect(object["method"] as? String == "account/rateLimitResetCredit/consume")
    #expect(params["idempotencyKey"] as? String == "attempt-1")
    #expect(params["creditId"] as? String == "opaque-credit")
}

@Test func authoritativeBucketMapCannotFallBackToAnonymousTopLevelWeeklyLimit() {
    let anonymousWeekly = RPCRateLimitSnapshot(
        limitID: nil,
        limitName: nil,
        primary: RPCRateLimitWindow(
            usedPercent: 100,
            windowDurationMinutes: 10_080,
            resetsAt: 2_000_100_000
        ),
        secondary: nil
    )
    let spark = RPCRateLimitSnapshot(
        limitID: "codex_spark",
        limitName: "Codex Spark Weekly",
        primary: anonymousWeekly.primary,
        secondary: nil
    )
    let response = RPCRateLimitsReadResponse(
        rateLimits: anonymousWeekly,
        rateLimitsByLimitID: ["codex_spark": spark],
        rateLimitResetCredits: RPCResetCreditsSummary(availableCount: 1, credits: nil)
    )

    #expect(response.canonicalCodexRateLimits == nil)
}

@Test func clientHandshakesAndSerializesProfileRequests() async throws {
    let transport = ControlledAppServerTransport()
    let client = AppServerClient(
        profileID: UUID(),
        transportFactory: { transport },
        requestTimeout: .seconds(2),
        restartDelays: []
    )
    try await client.start()

    let accountTask = Task { try await client.accountRead() }
    try await waitUntil { await transport.sentMethods().contains("account/read") }

    let rateLimitsTask = Task { try await client.readRateLimits() }
    try await Task.sleep(for: .milliseconds(40))
    #expect(await !transport.sentMethods().contains("account/rateLimits/read"))

    await transport.replyToAccountRead()
    let account = try await accountTask.value
    #expect(account.account?.type == "chatgpt")

    try await waitUntil { await transport.sentMethods().contains("account/rateLimits/read") }
    await transport.replyToRateLimitsRead()
    let rateLimits = try await rateLimitsTask.value
    #expect(rateLimits.canonicalCodexRateLimits?.limitID == "codex")

    let sentMethods = await transport.sentMethods()
    #expect(sentMethods.prefix(2) == ["initialize", "initialized"])
    #expect(sentMethods.filter { $0 == "account/read" }.count == 1)
    #expect(sentMethods.filter { $0 == "account/rateLimits/read" }.count == 1)
    await client.shutdown()
}

@Test func clientTimesOutWhenFixtureNeverReplies() async throws {
    let transport = ControlledAppServerTransport()
    let client = AppServerClient(
        profileID: UUID(),
        transportFactory: { transport },
        requestTimeout: .milliseconds(40),
        restartDelays: []
    )
    try await client.start()

    do {
        _ = try await client.accountRead()
        Issue.record("Expected account/read to time out")
    } catch let error as AppServerClientError {
        #expect(error == .timedOut(method: "account/read"))
    }
    await client.shutdown()
}

@Test func consumeOutcomeMapsWithoutInference() throws {
    for outcome in RPCConsumeResetOutcome.allCases {
        let data = Data(#"{"outcome":"\#(outcome.rawValue)"}"#.utf8)
        let response = try JSONDecoder().decode(RPCConsumeResetResponse.self, from: data)
        #expect(response.outcome == outcome)
        #expect(response.outcome.domainValue.rawValue == outcome.rawValue)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}

private actor ControlledAppServerTransport: AppServerTransport {
    private var isStarted = false
    private var isStopped = false
    private var messages: [Data] = []
    private var waiters: [CheckedContinuation<Data?, any Error>] = []
    private var methods: [String] = []
    private var accountRequestID: Int64?
    private var rateLimitsRequestID: Int64?

    func start() async throws {
        isStarted = true
    }

    func send(_ message: Data) async throws {
        guard isStarted, !isStopped else { throw AppServerTransportError.transportClosed }
        let object = try JSONSerialization.jsonObject(with: message) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        methods.append(method)

        switch method {
        case "initialize":
            let id = (object?["id"] as? NSNumber)?.int64Value ?? 0
            emit(#"{"id":\#(id),"result":{"userAgent":"fixture","platformFamily":"unix","platformOs":"macos","codexHome":"/fixture"}}"#)
        case "account/read":
            accountRequestID = (object?["id"] as? NSNumber)?.int64Value
        case "account/rateLimits/read":
            rateLimitsRequestID = (object?["id"] as? NSNumber)?.int64Value
        default:
            break
        }
    }

    func receive() async throws -> Data? {
        if !messages.isEmpty { return messages.removeFirst() }
        if isStopped { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func stop() async {
        isStopped = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    func sentMethods() -> [String] {
        methods
    }

    func replyToAccountRead() {
        guard let id = accountRequestID else { return }
        emit(#"{"id":\#(id),"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}"#)
    }

    func replyToRateLimitsRead() {
        guard let id = rateLimitsRequestID else { return }
        emit(#"{"id":\#(id),"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785000000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785600000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785000000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785600000}}},"rateLimitResetCredits":{"availableCount":1,"credits":null}}}"#)
    }

    private func emit(_ json: String) {
        let data = Data(json.utf8)
        if waiters.isEmpty {
            messages.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }
}
