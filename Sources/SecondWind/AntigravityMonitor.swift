import Foundation
import SecondWindCore

struct AntigravityProfile {
    var name = "Local CLI"
    var quota: QuotaAccountRecord
    var problem: String?

    var ref: AccountRef { AccountRef(quota) }

    func display(at date: Date) -> AccountQuotaDisplay {
        QuotaDisplayBuilder.display(reading: quota.reading(at: date), now: date) { _ in
            QuotaReadPolicy.standard(for: .antigravity).lowRemainingPercent
        }
    }
}

/// agy owns the Google sign-in. Its usage command identifies model groups, but does not
/// identify the signed-in person, so this monitor belongs to the CLI on this Mac.
@MainActor
final class AntigravityMonitor {
    private static let preference = "antigravity.localMonitor"
    private static let stopped = "Polling paused. Check /usage in agy, then retry. The CLI did not confirm zero model usage."
    private let model: GuardAppModel
    private let defaults: UserDefaults
    private let didEnroll: () -> Void
    private let read: @Sendable () async throws -> QuotaObservation
    private var poll: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var paused = false

    init(model: GuardAppModel, defaults: UserDefaults = .standard, didEnroll: @escaping () -> Void = {},
         read: @escaping @Sendable () async throws -> QuotaObservation) {
        self.model = model
        self.defaults = defaults
        self.didEnroll = didEnroll
        self.read = read
    }

    func start() {
        model.onAddAntigravity = { [weak self] in self?.add() }
        model.onRetryAntigravity = { [weak self] in self?.retry() }
        if let saved = defaults.dictionary(forKey: Self.preference),
           let raw = saved["id"] as? String, let id = UUID(uuidString: raw) {
            paused = saved["paused"] as? Bool == true
            var record = QuotaAccountRecord(provider: .antigravity, accountID: id)
            if paused { record.recordFailure(.monitoringStopped, at: Date()) }
            model.antigravity = AntigravityProfile(name: saved["name"] as? String ?? "Local CLI",
                                                  quota: record, problem: paused ? Self.stopped : nil)
        }
        publish()
        schedule()
    }

    func add() {
        defer { model.isAddingProfile = false }
        guard model.antigravity == nil else { return }
        model.antigravity = AntigravityProfile(quota: QuotaAccountRecord(provider: .antigravity, accountID: UUID()))
        model.enrollment = nil
        didEnroll()
        save()
        publish()
        schedule()
    }

    func rename(_ id: UUID, to raw: String) throws {
        guard model.antigravity?.ref.id == id else { throw AccountLifecycleError.accountNotFound }
        guard let name = AccountNameRules.normalized(raw, maximumLength: 48) else { throw AccountLifecycleError.invalidName }
        model.antigravity?.name = name
        save()
        publish()
    }

    func remove(_ id: UUID) throws {
        guard model.antigravity?.ref.id == id else { throw AccountLifecycleError.accountNotFound }
        stop()
        model.antigravity = nil
        paused = false
        defaults.removeObject(forKey: Self.preference)
        publish()
    }

    func stop() {
        poll?.cancel()
        refresh?.cancel()
        poll = nil
        refresh = nil
        model.isCheckingAntigravity = false
    }

    private func retry() {
        guard paused else { checkNow(); return }
        paused = false
        save()
        schedule()
    }

    private func save() {
        guard let profile = model.antigravity else { return }
        defaults.set(["id": profile.ref.id.uuidString, "name": profile.name, "paused": paused], forKey: Self.preference)
    }

    private func publish() {
        model.onQuotaRecordsChanged?(.antigravity, model.antigravity.map { [$0.quota] } ?? [])
    }

    private func schedule() {
        guard model.antigravity != nil, !paused, poll == nil else { return }
        checkNow()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.checkNow()
            }
        }
    }

    func checkNow() {
        guard let ref = model.antigravity?.ref, !paused, refresh == nil else { return }
        model.isCheckingAntigravity = true
        refresh = Task {
            let result: Result<QuotaObservation, Error>
            do { result = .success(try await read()) } catch { result = .failure(error) }
            guard !Task.isCancelled, var profile = model.antigravity, profile.ref == ref else { return }
            switch result {
            case let .success(observation):
                profile.quota.recordSuccess(observation)
                profile.problem = nil
            case let .failure(error):
                var reason = QuotaFailureReason.unavailable
                switch error as? AntigravityUsageError {
                case .unverifiedCommand:
                    paused = true
                    poll?.cancel()
                    poll = nil
                    save()
                    reason = .monitoringStopped
                    profile.problem = Self.stopped
                case .missingCLI:
                    profile.problem = "Install the Antigravity CLI and sign in with agy, then check again."
                case .unreadable:
                    reason = .unreadable
                    profile.problem = "agy returned an unreadable quota report. Update agy and check again."
                case .unavailable, nil:
                    profile.problem = "Open agy and check /usage, then try again here."
                }
                profile.quota.recordFailure(reason, at: Date())
            }
            model.antigravity = profile
            model.lastCheckedAt = Date()
            model.isCheckingAntigravity = false
            refresh = nil
            publish()
        }
    }
}
