import AppKit
import Foundation
import SwiftUI

enum PreviewKind: String, CaseIterable {
    case onboarding
    case onboardingError = "onboarding-error"
    case connect
    case paused
    case healthy
    case near
    case redeemed
    case authError = "auth-error"
    case overview
    case claudeLow = "claude-low"
    case claudeSignIn = "claude-signin"
}

@MainActor
enum PreviewFixtures {
    static func model(for kind: PreviewKind) -> GuardAppModel {
        let reference = Date(timeIntervalSince1970: 1_785_300_000)
        let commonSecond = GuardProfilePresentation(
            id: "profile-two",
            displayName: "Work",
            accountHint: "Account 2",
            weeklyRemainingPercent: 58,
            naturalResetAt: reference.addingTimeInterval(4 * 86_400),
            availableResetCount: 1,
            nearestResetExpiry: reference.addingTimeInterval(18 * 86_400),
            status: .healthy,
            detail: "Checked every 60 seconds.",
            autoResetEnabled: true
        )

        func claude(
            _ name: String,
            hint: String,
            plan: String? = "Max",
            session: Double?,
            weekly: Double?,
            sonnet: Double? = nil,
            status: ClaudeProfileStatus,
            detail: String
        ) -> ClaudeProfilePresentation {
            var windows: [ClaudeWindowPresentation] = []
            if let session {
                windows.append(.init(id: "session", label: "5-hour", remainingPercent: session, resetsAt: reference.addingTimeInterval(3 * 3_600 + 40 * 60)))
            }
            if let weekly {
                windows.append(.init(id: "weekly", label: "Weekly", remainingPercent: weekly, resetsAt: reference.addingTimeInterval(5 * 86_400 + 9 * 3_600)))
            }
            if let sonnet {
                windows.append(.init(id: "weekly:Sonnet only", label: "Sonnet", remainingPercent: sonnet, resetsAt: reference.addingTimeInterval(5 * 86_400 + 9 * 3_600)))
            }
            return ClaudeProfilePresentation(
                id: "claude-\(name.lowercased())", displayName: name, accountHint: hint, planName: plan,
                windows: windows, status: status, detail: detail, signInURL: nil
            )
        }

        switch kind {
        case .overview:
            return GuardAppModel(
                profiles: [
                    GuardProfilePresentation(
                        id: "profile-one", displayName: "Personal", accountHint: "n•••@example.com",
                        weeklyRemainingPercent: 61, naturalResetAt: reference.addingTimeInterval(6 * 86_400),
                        availableResetCount: 2, nearestResetExpiry: reference.addingTimeInterval(14 * 86_400),
                        status: .healthy, detail: "Checked every 60 seconds.", autoResetEnabled: true
                    ),
                ],
                claudeProfiles: [
                    claude("Studio", hint: "s•••@example.com", session: 42, weekly: 71, status: .healthy, detail: "Checked every 5 minutes."),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .claudeLow:
            return GuardAppModel(
                profiles: [commonSecond],
                claudeProfiles: [
                    claude("Studio", hint: "s•••@example.com", session: 64, weekly: 7, sonnet: 31, status: .low, detail: "Use a reset from Claude settings if you have one."),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .claudeSignIn:
            return GuardAppModel(
                claudeProfiles: [
                    claude("Studio", hint: "s•••@example.com", plan: nil, session: nil, weekly: nil, status: .signingIn, detail: "Finish signing in in your browser."),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .onboarding:
            return GuardAppModel(isPreview: true, referenceDate: reference)
        case .onboardingError:
            let model = GuardAppModel(isPreview: true, referenceDate: reference)
            model.enrollmentError = "Enter the email address you use to sign in to Codex."
            return model
        case .connect:
            return GuardAppModel(profiles: [
                GuardProfilePresentation(
                    id: "profile-one", displayName: "Personal", accountHint: "p•••@example.com",
                    weeklyRemainingPercent: nil, naturalResetAt: nil, availableResetCount: 0,
                    nearestResetExpiry: nil, status: .disconnected,
                    detail: "Connect this profile to sign in securely.", autoResetEnabled: false,
                    identityVerified: false
                ),
            ], isPreview: true, referenceDate: reference)
        case .paused:
            var profile = commonSecond
            profile.displayName = "Personal"
            profile.accountHint = "p•••@example.com"
            profile.autoResetEnabled = false
            profile.detail = "Automatic weekly reset is paused."
            return GuardAppModel(profiles: [profile], isPreview: true, referenceDate: reference)
        case .healthy:
            return GuardAppModel(profiles: [
                GuardProfilePresentation(
                    id: "profile-one", displayName: "Personal", accountHint: "Account 1",
                    weeklyRemainingPercent: 61, naturalResetAt: reference.addingTimeInterval(6 * 86_400),
                    availableResetCount: 2, nearestResetExpiry: reference.addingTimeInterval(14 * 86_400),
                    status: .healthy, detail: "Checked every 60 seconds.", autoResetEnabled: true
                ),
                commonSecond,
            ], isPreview: true, referenceDate: reference)
        case .near:
            return GuardAppModel(profiles: [
                GuardProfilePresentation(
                    id: "profile-one", displayName: "Personal", accountHint: "Account 1",
                    weeklyRemainingPercent: 2.6, naturalResetAt: reference.addingTimeInterval(2 * 86_400),
                    availableResetCount: 2, nearestResetExpiry: reference.addingTimeInterval(14 * 86_400),
                    status: .confirming, detail: "Reading 1 of 2 · checking again in 5 seconds", autoResetEnabled: true
                ),
                commonSecond,
            ], isPreview: true, referenceDate: reference)
        case .redeemed:
            return GuardAppModel(
                profiles: [
                    GuardProfilePresentation(
                        id: "profile-one", displayName: "Personal", accountHint: "Account 1",
                        weeklyRemainingPercent: 100, naturalResetAt: reference.addingTimeInterval(7 * 86_400),
                        availableResetCount: 1, nearestResetExpiry: reference.addingTimeInterval(15 * 86_400),
                        status: .verified, detail: "Monitoring resumed", autoResetEnabled: true
                    ),
                    commonSecond,
                ],
                history: [
                    GuardHistoryEvent(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, occurredAt: reference, profileName: "Personal", summary: "Weekly reset redeemed and verified")
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .authError:
            return GuardAppModel(profiles: [
                GuardProfilePresentation(
                    id: "profile-one", displayName: "Personal", accountHint: "Account 1",
                    weeklyRemainingPercent: 61, naturalResetAt: reference.addingTimeInterval(6 * 86_400),
                    availableResetCount: 2, nearestResetExpiry: reference.addingTimeInterval(14 * 86_400),
                    status: .healthy, detail: "Checked every 60 seconds.", autoResetEnabled: true
                ),
                GuardProfilePresentation(
                    id: "profile-two", displayName: "Work", accountHint: "Expected identity: Work Codex",
                    weeklyRemainingPercent: nil, naturalResetAt: nil, availableResetCount: 0,
                    nearestResetExpiry: nil, status: .disconnected,
                    detail: "Authentication expired. Reconnect this isolated profile.", autoResetEnabled: true
                ),
            ], isPreview: true, referenceDate: reference)
        }
    }

    static func validate() throws {
        for kind in PreviewKind.allCases {
            let model = model(for: kind)
            let expectedCount: Int = switch kind {
            case .onboarding, .onboardingError: 0
            case .connect, .paused, .claudeSignIn: 1
            default: 2
            }
            let ids = model.profiles.map(\.id) + model.claudeProfiles.map(\.id)
            guard ids.count == expectedCount else { throw PreviewError.invalidProfileCount(kind) }
            guard Set(ids).count == ids.count else {
                throw PreviewError.duplicateProfileID(kind)
            }
            let remaining = model.profiles.compactMap(\.weeklyRemainingPercent)
                + model.claudeProfiles.flatMap { $0.windows.map(\.remainingPercent) }
            guard remaining.allSatisfy({ (0...100).contains($0) }) else {
                throw PreviewError.invalidRemaining(kind)
            }
        }
    }
}

enum PreviewError: LocalizedError {
    case invalidProfileCount(PreviewKind)
    case duplicateProfileID(PreviewKind)
    case invalidRemaining(PreviewKind)

    var errorDescription: String? {
        switch self {
        case let .invalidProfileCount(kind): "Preview \(kind.rawValue) has an unexpected profile count."
        case let .duplicateProfileID(kind): "Preview \(kind.rawValue) contains duplicate profile IDs."
        case let .invalidRemaining(kind): "Preview \(kind.rawValue) contains invalid remaining usage."
        }
    }
}

@MainActor
enum PreviewRenderer {
    static func render(kind: PreviewKind, to destination: URL) throws {
        // ImageRenderer cannot materialize an AppKit-backed ScrollView offscreen. The
        // deterministic canvas uses the exact production popover dimensions.
        let view = GuardPopoverView(
            model: PreviewFixtures.model(for: kind),
            canvasHeight: 560,
            isStaticRender: true
        )
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var png: Data?
        // Dynamic palette colours resolve against the current drawing appearance.
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff) {
                png = bitmap.representation(using: .png, properties: [:])
            }
        }
        guard let png else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: destination, options: .atomic)
    }
}
