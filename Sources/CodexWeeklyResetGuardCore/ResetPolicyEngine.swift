import Foundation

public enum ResetPolicyAction: Sendable, Equatable {
    case none
    /// Persist the returned state atomically, then consume with this attempt.
    case persistThenConsume(RedemptionAttempt)
    /// A prior request had an ambiguous result; consume again with the same attempt and key.
    case retryConsume(RedemptionAttempt)
    case readForVerification(RedemptionAttempt)
}

public enum ResetPolicyReason: String, Sendable, Equatable {
    case disabled
    case staleReading
    case futureReading
    case healthy
    case nearLimit
    case firstConfirmation
    case duplicateReading
    case confirmationTooSoon
    case resetEpochChanged
    case noCredits
    case missingIdempotencyKey
    case attemptPrepared
    case attemptInFlight
    case retryableAttempt
    case awaitingVerification
    case alreadyVerified
    case waitingForUsageDecrease
    case waitingForNothingToResetBackoff
    case requestRejected
    case terminalFailure
}

public struct ResetPolicyEvaluation: Sendable, Equatable {
    public var state: MonitorState
    public var action: ResetPolicyAction
    public var reason: ResetPolicyReason

    public init(state: MonitorState, action: ResetPolicyAction, reason: ResetPolicyReason) {
        self.state = state
        self.action = action
        self.reason = reason
    }
}

public enum ResetPolicyTransitionError: Error, Sendable, Equatable {
    case missingAttempt
    case invalidAttemptPhase(RedemptionAttemptPhase)
    case invalidIdempotencyKey
    case invalidAttemptProfile
}

/// A deterministic state machine. Callers supply idempotency keys and time, then persist the
/// returned `MonitorState`; this core never performs I/O or generates nondeterministic values.
public struct ResetPolicyEngine: Sendable {
    public var redemptionThresholdPercent: Double
    public var nearLimitThresholdPercent: Double
    public var requiredConfirmations: Int
    public var minimumConfirmationInterval: TimeInterval
    public var maximumReadingAge: TimeInterval
    public var maximumFutureSkew: TimeInterval
    public var verificationTimeout: TimeInterval
    public var nothingToResetRetryInterval: TimeInterval

    public init(
        redemptionThresholdPercent: Double = 3,
        nearLimitThresholdPercent: Double = 10,
        requiredConfirmations: Int = 2,
        minimumConfirmationInterval: TimeInterval = 5,
        maximumReadingAge: TimeInterval = 120,
        maximumFutureSkew: TimeInterval = 5,
        verificationTimeout: TimeInterval = 60,
        nothingToResetRetryInterval: TimeInterval = 60
    ) {
        self.redemptionThresholdPercent = redemptionThresholdPercent
        self.nearLimitThresholdPercent = nearLimitThresholdPercent
        self.requiredConfirmations = max(2, requiredConfirmations)
        self.minimumConfirmationInterval = max(0, minimumConfirmationInterval)
        self.maximumReadingAge = maximumReadingAge
        self.maximumFutureSkew = maximumFutureSkew
        self.verificationTimeout = verificationTimeout
        self.nothingToResetRetryInterval = max(30, nothingToResetRetryInterval)
    }

    public func evaluate(
        weeklyLimit: CanonicalWeeklyLimit,
        inventory: ResetCreditInventory,
        state originalState: MonitorState,
        now: Date,
        newIdempotencyKey: String? = nil
    ) -> ResetPolicyEvaluation {
        var state = originalState
        var reuseFreshConfirmation = false

        guard state.isEnabled else {
            state.phase = .disabled
            return ResetPolicyEvaluation(state: state, action: .none, reason: .disabled)
        }

        let age = now.timeIntervalSince(weeklyLimit.observedAt)
        guard age <= maximumReadingAge else {
            return attention(
                state,
                message: "The weekly usage reading is stale.",
                reason: .staleReading
            )
        }
        guard age >= -maximumFutureSkew else {
            return attention(
                state,
                message: "The weekly usage reading is timestamped in the future.",
                reason: .futureReading
            )
        }

        state.lastWeeklyLimit = weeklyLimit
        state.attentionMessage = nil

        if let attempt = state.attempt {
            guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
                  attempt.profileID == state.profileID else {
                return attention(
                    state,
                    message: "The saved reset attempt does not belong to this profile.",
                    reason: .terminalFailure
                )
            }
            switch attempt.phase {
            case .prepared:
                // A prepared attempt has not crossed the network boundary. Retire it if its
                // actual confirmation pair has aged out, including old state without timestamps
                // for both readings. A restart must not refresh stale evidence implicitly.
                guard weeklyLimit.resetsAt == attempt.weeklyResetAtBefore,
                      weeklyLimit.remainingPercent <= redemptionThresholdPercent,
                      hasFreshConfirmation(
                        state.confirmation,
                        for: weeklyLimit.resetsAt,
                        at: now
                      ) else {
                    state.attempt = nil
                    state.confirmation = nil
                    break
                }
                if var confirmation = state.confirmation,
                   weeklyLimit.observedAt > confirmation.lastObservedAt {
                    confirmation.lastObservedAt = weeklyLimit.observedAt
                    confirmation.lastRemainingPercent = weeklyLimit.remainingPercent
                    state.confirmation = confirmation
                }
                state.phase = .redeeming
                return ResetPolicyEvaluation(
                    state: state,
                    action: .persistThenConsume(attempt),
                    reason: .attemptPrepared
                )
            case .requestInFlight:
                state.phase = .redeeming
                return ResetPolicyEvaluation(
                    state: state,
                    action: .retryConsume(attempt),
                    reason: .attemptInFlight
                )
            case .retryable:
                state.phase = .redeeming
                return ResetPolicyEvaluation(
                    state: state,
                    action: .retryConsume(attempt),
                    reason: .retryableAttempt
                )
            case .awaitingVerification:
                state.phase = .verifying
                return ResetPolicyEvaluation(
                    state: state,
                    action: .readForVerification(attempt),
                    reason: .awaitingVerification
                )
            case .succeeded:
                // Strong verification already proved this logical request. Retire it so a later
                // depletion in the same natural week can use another banked reset after two new
                // fresh readings.
                state.attempt = nil
                state.confirmation = nil
            case .nothingToReset:
                if weeklyLimit.resetsAt != attempt.weeklyResetAtBefore
                    || weeklyLimit.remainingPercent > redemptionThresholdPercent {
                    state.attempt = nil
                    state.confirmation = nil
                    break
                }
                let priorRemaining = max(0, 100 - attempt.weeklyUsedPercentBefore)
                let decreased = weeklyLimit.remainingPercent < priorRemaining
                let justReachedZero = weeklyLimit.remainingPercent == 0 && priorRemaining > 0
                let zeroBackoffElapsed = weeklyLimit.remainingPercent == 0
                    && now.timeIntervalSince(attempt.updatedAt) >= nothingToResetRetryInterval
                guard decreased || justReachedZero || zeroBackoffElapsed else {
                    state.phase = .confirming
                    return ResetPolicyEvaluation(
                        state: state,
                        action: .none,
                        reason: weeklyLimit.remainingPercent == 0
                            ? .waitingForNothingToResetBackoff
                            : .waitingForUsageDecrease
                    )
                }
                state.attempt = nil
                // A definite no-op may rearm using the same actual fresh pair. Never fabricate
                // an earlier reading; after sleep or a long backoff the pair must be collected anew.
                reuseFreshConfirmation = hasFreshConfirmation(
                    state.confirmation,
                    for: weeklyLimit.resetsAt,
                    at: now
                )
                if !reuseFreshConfirmation { state.confirmation = nil }
            case .noCredit:
                guard inventory.availableCount > 0 else {
                    state.phase = .noCredits
                    return ResetPolicyEvaluation(state: state, action: .none, reason: .noCredits)
                }
                state.attempt = nil
                state.confirmation = nil
            case .requestRejected:
                state.phase = .attentionRequired
                state.attentionMessage = "Codex rejected the saved-reset request. Reconnect or pause this profile before retrying."
                return ResetPolicyEvaluation(
                    state: state,
                    action: .none,
                    reason: .requestRejected
                )
            case .verificationFailed:
                state.phase = .attentionRequired
                state.attentionMessage = "A reset credit changed without a verified weekly recovery."
                // The request may have crossed the network boundary, so never mint a new key.
                // Continue read-only reconciliation on every fresh poll to recognize late success.
                return ResetPolicyEvaluation(
                    state: state,
                    action: .readForVerification(attempt),
                    reason: .terminalFailure
                )
            }
        }

        if weeklyLimit.remainingPercent > nearLimitThresholdPercent {
            state.phase = .healthy
            state.confirmation = nil
            return ResetPolicyEvaluation(state: state, action: .none, reason: .healthy)
        }

        if weeklyLimit.remainingPercent > redemptionThresholdPercent {
            state.phase = .nearLimit
            state.confirmation = nil
            return ResetPolicyEvaluation(state: state, action: .none, reason: .nearLimit)
        }

        if !reuseFreshConfirmation {
            var confirmation = state.confirmation
            if let existing = confirmation,
               !hasFreshObservationSequence(existing, at: now) {
                confirmation = nil
                state.confirmation = nil
            }
            if confirmation?.weeklyResetAt != weeklyLimit.resetsAt {
                confirmation = ThresholdConfirmation(
                    weeklyResetAt: weeklyLimit.resetsAt,
                    count: 1,
                    lastObservedAt: weeklyLimit.observedAt,
                    lastRemainingPercent: weeklyLimit.remainingPercent,
                    firstObservedAt: weeklyLimit.observedAt
                )
                state.confirmation = confirmation
                state.phase = .confirming
                return ResetPolicyEvaluation(
                    state: state,
                    action: .none,
                    reason: originalState.confirmation?.weeklyResetAt != nil
                        && originalState.confirmation?.weeklyResetAt != weeklyLimit.resetsAt
                        ? .resetEpochChanged : .firstConfirmation
                )
            }

            guard let existingConfirmation = confirmation else {
                // Defensive fallback; the reset-epoch branch above normally creates it.
                state.confirmation = ThresholdConfirmation(
                    weeklyResetAt: weeklyLimit.resetsAt,
                    count: 1,
                    lastObservedAt: weeklyLimit.observedAt,
                    lastRemainingPercent: weeklyLimit.remainingPercent,
                    firstObservedAt: weeklyLimit.observedAt
                )
                state.phase = .confirming
                return ResetPolicyEvaluation(state: state, action: .none, reason: .firstConfirmation)
            }

            guard weeklyLimit.observedAt > existingConfirmation.lastObservedAt else {
                state.phase = .confirming
                return ResetPolicyEvaluation(state: state, action: .none, reason: .duplicateReading)
            }

            guard weeklyLimit.observedAt.timeIntervalSince(existingConfirmation.lastObservedAt)
                >= minimumConfirmationInterval
            else {
                state.phase = .confirming
                return ResetPolicyEvaluation(
                    state: state,
                    action: .none,
                    reason: .confirmationTooSoon
                )
            }

            confirmation = ThresholdConfirmation(
                weeklyResetAt: existingConfirmation.weeklyResetAt,
                count: existingConfirmation.count + 1,
                lastObservedAt: weeklyLimit.observedAt,
                lastRemainingPercent: weeklyLimit.remainingPercent,
                firstObservedAt: existingConfirmation.firstObservedAt
                    ?? existingConfirmation.lastObservedAt
            )
            state.confirmation = confirmation

            guard confirmation!.count >= requiredConfirmations else {
                state.phase = .confirming
                return ResetPolicyEvaluation(state: state, action: .none, reason: .firstConfirmation)
            }
        }

        guard inventory.availableCount > 0 else {
            state.phase = .noCredits
            return ResetPolicyEvaluation(state: state, action: .none, reason: .noCredits)
        }


        let selectedCredit = inventory.earliestExpiringAvailableCodexCredit(at: now)
        guard inventory.credits == nil || selectedCredit != nil else {
            state.phase = .noCredits
            return ResetPolicyEvaluation(state: state, action: .none, reason: .noCredits)
        }

        guard let newIdempotencyKey,
              !newIdempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return attention(
                state,
                message: "A durable idempotency key is required before redemption.",
                reason: .missingIdempotencyKey
            )
        }

        let attempt = RedemptionAttempt(
            profileID: state.profileID,
            idempotencyKey: newIdempotencyKey,
            creditID: selectedCredit?.id,
            weeklyResetAtBefore: weeklyLimit.resetsAt,
            weeklyUsedPercentBefore: weeklyLimit.usedPercent,
            availableCreditCountBefore: inventory.availableCount,
            preparedAt: now
        )
        state.attempt = attempt
        state.phase = .redeeming
        return ResetPolicyEvaluation(
            state: state,
            action: .persistThenConsume(attempt),
            reason: .attemptPrepared
        )
    }

    /// Proves that every reading counted toward a never-sent request is still fresh. Call this
    /// again at the final consume boundary because persistence or a device sleep can take time.
    public func hasFreshConfirmation(
        _ confirmation: ThresholdConfirmation?,
        for weeklyResetAt: Date,
        at now: Date
    ) -> Bool {
        guard let confirmation,
              let firstObservedAt = confirmation.firstObservedAt,
              confirmation.weeklyResetAt == weeklyResetAt,
              confirmation.count >= requiredConfirmations,
              confirmation.lastRemainingPercent.isFinite,
              confirmation.lastRemainingPercent >= 0,
              confirmation.lastRemainingPercent <= redemptionThresholdPercent,
              hasFreshObservationSequence(confirmation, at: now) else {
            return false
        }
        return confirmation.lastObservedAt.timeIntervalSince(firstObservedAt)
            >= minimumConfirmationInterval * Double(requiredConfirmations - 1)
    }

    private func hasFreshObservationSequence(
        _ confirmation: ThresholdConfirmation,
        at now: Date
    ) -> Bool {
        // A legacy one-reading confirmation still identifies its only actual observation.
        // A legacy multi-reading count does not establish the age of its oldest evidence.
        guard let firstObservedAt = confirmation.firstObservedAt
            ?? (confirmation.count == 1 ? confirmation.lastObservedAt : nil),
              firstObservedAt <= confirmation.lastObservedAt else {
            return false
        }
        return now.timeIntervalSince(firstObservedAt) <= maximumReadingAge
            && now.timeIntervalSince(confirmation.lastObservedAt) >= -maximumFutureSkew
    }

    public func markRequestStarted(
        in originalState: MonitorState,
        at now: Date
    ) throws -> MonitorState {
        var state = originalState
        guard var attempt = state.attempt else {
            throw ResetPolicyTransitionError.missingAttempt
        }
        guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
              attempt.profileID == state.profileID else {
            throw ResetPolicyTransitionError.invalidAttemptProfile
        }
        guard !attempt.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResetPolicyTransitionError.invalidIdempotencyKey
        }
        guard [.prepared, .retryable, .requestInFlight].contains(attempt.phase) else {
            throw ResetPolicyTransitionError.invalidAttemptPhase(attempt.phase)
        }
        attempt.phase = .requestInFlight
        attempt.updatedAt = now
        state.attempt = attempt
        state.phase = .redeeming
        state.attentionMessage = nil
        return state
    }

    public func recordAmbiguousFailure(
        in originalState: MonitorState,
        at now: Date
    ) throws -> MonitorState {
        var state = originalState
        guard var attempt = state.attempt else {
            throw ResetPolicyTransitionError.missingAttempt
        }
        guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
              attempt.profileID == state.profileID else {
            throw ResetPolicyTransitionError.invalidAttemptProfile
        }
        guard attempt.phase == .requestInFlight else {
            throw ResetPolicyTransitionError.invalidAttemptPhase(attempt.phase)
        }
        attempt.phase = .retryable
        attempt.updatedAt = now
        state.attempt = attempt
        state.phase = .redeeming
        return state
    }

    public func recordConsumeOutcome(
        _ outcome: ConsumeResetOutcome,
        in originalState: MonitorState,
        at now: Date
    ) throws -> MonitorState {
        var state = originalState
        guard var attempt = state.attempt else {
            throw ResetPolicyTransitionError.missingAttempt
        }
        guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
              attempt.profileID == state.profileID else {
            throw ResetPolicyTransitionError.invalidAttemptProfile
        }
        guard attempt.phase == .requestInFlight else {
            throw ResetPolicyTransitionError.invalidAttemptPhase(attempt.phase)
        }

        attempt.consumeOutcome = outcome
        attempt.updatedAt = now
        switch outcome {
        case .reset, .alreadyRedeemed:
            attempt.phase = .awaitingVerification
            state.phase = .verifying
        case .nothingToReset:
            attempt.phase = .nothingToReset
            state.phase = .confirming
        case .noCredit:
            attempt.phase = .noCredit
            state.phase = .noCredits
        }
        state.attempt = attempt
        return state
    }

    /// Records a definite server-side rejection. Unlike a transport timeout/close, this phase is
    /// never retried automatically and can be cleared safely by an explicit disable/re-enable.
    public func recordDefiniteRejection(
        in originalState: MonitorState,
        at now: Date
    ) throws -> MonitorState {
        var state = originalState
        guard var attempt = state.attempt else {
            throw ResetPolicyTransitionError.missingAttempt
        }
        guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
              attempt.profileID == state.profileID else {
            throw ResetPolicyTransitionError.invalidAttemptProfile
        }
        guard attempt.phase == .requestInFlight else {
            throw ResetPolicyTransitionError.invalidAttemptPhase(attempt.phase)
        }
        attempt.phase = .requestRejected
        attempt.updatedAt = now
        state.attempt = attempt
        state.phase = .attentionRequired
        state.attentionMessage = "Codex rejected the saved-reset request; it will not be retried automatically."
        return state
    }

    /// Reconciles a successful consume response against a fresh read. Success requires both
    /// weekly recovery and an authoritative decrease in available credits.
    public func reconcileVerification(
        weeklyLimit: CanonicalWeeklyLimit,
        inventory: ResetCreditInventory,
        in originalState: MonitorState,
        now: Date
    ) throws -> MonitorState {
        var state = originalState
        guard var attempt = state.attempt else {
            throw ResetPolicyTransitionError.missingAttempt
        }
        guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
              attempt.profileID == state.profileID else {
            throw ResetPolicyTransitionError.invalidAttemptProfile
        }
        guard [.awaitingVerification, .verificationFailed].contains(attempt.phase) else {
            throw ResetPolicyTransitionError.invalidAttemptPhase(attempt.phase)
        }

        let weeklyChanged = weeklyLimit.resetsAt != attempt.weeklyResetAtBefore
            || weeklyLimit.usedPercent < attempt.weeklyUsedPercentBefore
        // A reset is expected to restore substantial headroom. Tiny usage jitter or a reset-epoch
        // change while the account remains near exhaustion is not sufficient proof.
        let weeklyRecovered = weeklyChanged
            && weeklyLimit.remainingPercent > nearLimitThresholdPercent
        let creditConsumed: Bool
        if let creditID = attempt.creditID {
            // When a specific opaque credit was selected, verify that exact credit is no longer
            // available. A total-count decrease could instead be an unrelated credit expiring.
            creditConsumed = inventory.credits.map { credits in
                !credits.contains { credit in
                    credit.id == creditID && credit.status == .available
                }
            } ?? false
        } else {
            creditConsumed = inventory.availableCount < attempt.availableCreditCountBefore
        }

        state.lastWeeklyLimit = weeklyLimit
        if weeklyRecovered && creditConsumed {
            attempt.phase = .succeeded
            attempt.updatedAt = now
            state.attempt = attempt
            state.phase = .verified
            state.confirmation = nil
            state.attentionMessage = nil
            return state
        }

        let timedOut = now.timeIntervalSince(attempt.updatedAt) >= verificationTimeout
        if creditConsumed || timedOut {
            if attempt.phase != .verificationFailed {
                attempt.phase = .verificationFailed
                attempt.updatedAt = now
            }
            state.attempt = attempt
            state.phase = .attentionRequired
            state.attentionMessage = creditConsumed
                ? "A reset credit disappeared, but the weekly limit did not recover."
                : "The reset outcome could not be verified before the deadline."
            return state
        }

        state.phase = attempt.phase == .verificationFailed ? .attentionRequired : .verifying
        return state
    }

    private func attention(
        _ originalState: MonitorState,
        message: String,
        reason: ResetPolicyReason
    ) -> ResetPolicyEvaluation {
        var state = originalState
        state.phase = .attentionRequired
        state.attentionMessage = message
        state.confirmation = nil
        return ResetPolicyEvaluation(state: state, action: .none, reason: reason)
    }
}
