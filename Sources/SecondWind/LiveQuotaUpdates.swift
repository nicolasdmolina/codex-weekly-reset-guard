import Foundation
import SecondWindCore

@MainActor
final class LiveQuotaUpdates {
    private enum Update {
        case roster(QuotaProvider, [QuotaAccountRecord])
        case flush(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Update>.Continuation
    private let worker: Task<Void, Never>

    init(
        snapshotFile: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        reportWriteFailure: @escaping () -> Void
    ) {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        self.continuation = continuation
        let publisher = PreflightSnapshotPublisher(fileURL: snapshotFile, runStartedAt: now())
        worker = Task {
            var reportedFailure = false
            do {
                try await publisher.clear(now: now())
            } catch {
                reportWriteFailure()
                reportedFailure = true
            }
            for await update in stream {
                switch update {
                case let .flush(acknowledge):
                    acknowledge.resume()
                case let .roster(provider, accounts):
                    do {
                        try await publisher.publish(provider: provider, records: accounts, now: now())
                        reportedFailure = false
                    } catch {
                        if !reportedFailure { reportWriteFailure() }
                        reportedFailure = true
                    }
                }
            }
            do {
                try await publisher.clear(now: now())
            } catch {
                if !reportedFailure { reportWriteFailure() }
            }
        }
    }

    func receive(_ provider: QuotaProvider, _ accounts: [QuotaAccountRecord]) {
        continuation.yield(.roster(provider, accounts))
    }

    func flush() async {
        await withCheckedContinuation { completion in
            if case .terminated = continuation.yield(.flush(completion)) { completion.resume() }
        }
    }

    func stop() async {
        continuation.finish()
        await worker.value
    }
}
