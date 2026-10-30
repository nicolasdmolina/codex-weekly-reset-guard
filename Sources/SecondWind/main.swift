import AppKit
import SecondWindCore
import Foundation

do {
    // Parsing must complete before constructing locks, runtimes, or NSApplication. In
    // particular, an invalid preview name must never fall through to production mode.
    let command = try GuardCommandLine.parse(
        Array(CommandLine.arguments.dropFirst()),
        bundledPreviewKind: Bundle.main.object(forInfoDictionaryKey: "GuardPreviewKind")
            .map { String(describing: $0) },
        bundledDiagnosticDirectory: Bundle.main.object(forInfoDictionaryKey: "GuardDiagnosticSupportDirectory")
            .map { String(describing: $0) }
    )

    if case let .renderPreview(kind, destinationPath) = command {
        try MainActor.assumeIsolated {
            try PreviewRenderer.render(kind: kind, to: URL(fileURLWithPath: destinationPath))
        }
        exit(0)
    }
    if case let .renderAllPreviews(directoryPath) = command {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try MainActor.assumeIsolated {
            for kind in PreviewKind.allCases {
                try PreviewRenderer.render(
                    kind: kind,
                    to: directory.appendingPathComponent("\(kind.rawValue).png")
                )
            }
        }
        exit(0)
    }
    if command == .selfTest {
        try MainActor.assumeIsolated { try PreviewFixtures.validate() }
        print("Second Wind executable self-test passed.")
        exit(0)
    }

    if command == .doctor {
        let doctorLock = try SingleInstanceLock(
            url: ProfileConfiguration.defaultApplicationSupportDirectory
                .appendingPathComponent("guard.lock", isDirectory: false)
        )
        Task {
            _ = doctorLock
            let controller = GuardRuntimeController(configuration: GuardRuntimeConfiguration())
            do {
                let snapshot = try await controller.diagnose()
                print("No-consume Codex diagnostic completed for \(snapshot.profiles.count) profiles.")
                for profile in snapshot.profiles {
                    let remaining = profile.weeklyRemainingPercent.map {
                        "\(Int($0.rounded()))% weekly remaining"
                    } ?? "weekly usage unavailable"
                    print("- \(profile.displayName): \(profile.connectionStatus.rawValue), \(remaining)")
                }
                exit(0)
            } catch {
                fputs("No-consume Codex diagnostic failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }

    let previewKind: PreviewKind?
    let runtimeConfiguration: GuardRuntimeConfiguration?
    switch command {
    case let .preview(kind):
        previewKind = kind
        runtimeConfiguration = nil
    case .production:
        previewKind = nil
        runtimeConfiguration = .production()
    case let .diagnosticUI(supportDirectory):
        previewKind = nil
        runtimeConfiguration = GuardRuntimeConfiguration(
            operationMode: .readOnly,
            applicationSupportDirectory: supportDirectory,
            profilesDirectory: supportDirectory.appendingPathComponent("profiles", isDirectory: true)
        )
    case .renderPreview, .renderAllPreviews, .selfTest, .doctor:
        preconditionFailure("A completed non-runtime command unexpectedly returned")
    }
    let model = MainActor.assumeIsolated {
        if let previewKind {
            PreviewFixtures.model(for: previewKind)
        } else {
            GuardAppModel(profiles: [], isPreview: false, isReadOnly: runtimeConfiguration?.operationMode == .readOnly)
        }
    }
    if command == .production {
        switch try LegacyStateMigration.migrateIfNeeded(
            legacyDirectory: ProfileConfiguration.legacyApplicationSupportDirectory,
            currentDirectory: ProfileConfiguration.defaultApplicationSupportDirectory
        ) {
        case .legacyAppRunning:
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = "Quit Codex Weekly Reset Guard first"
                alert.informativeText = "Second Wind replaces it. Quit the old app, then open Second Wind again to bring over your accounts."
                alert.runModal()
            }
            exit(1)
        case .migrated:
            MainActor.assumeIsolated {
                model.banner = "Your Codex accounts moved over from Codex Weekly Reset Guard. Turn launch at login back on from the ••• menu if you used it."
            }
        case .notNeeded:
            break
        }
    }
    let instanceLock = try runtimeConfiguration.map {
        try SingleInstanceLock(
            url: $0.applicationSupportDirectory
                .appendingPathComponent("guard.lock", isDirectory: false)
        )
    }
    _ = instanceLock
    let runtime = MainActor.assumeIsolated {
        runtimeConfiguration.map { makeGuardRuntimeController(model: model, configuration: $0) }
    }
    let claudeMonitor = MainActor.assumeIsolated {
        runtimeConfiguration.map { configuration in
            makeClaudeMonitor(model: model, configuration: ClaudeMonitorConfiguration(
                isReadOnly: configuration.operationMode == .readOnly,
                executableURL: ProcessClaudeCommandRunner.defaultExecutableURL,
                applicationSupportDirectory: configuration.applicationSupportDirectory
            ))
        }
    }
    MainActor.assumeIsolated {
        guard let runtime else { return }
        model.onCheckNow = { [weak runtime, weak claudeMonitor] in
            Task { _ = await runtime?.checkNow() }
            Task { await claudeMonitor?.checkNow() }
        }
    }
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated {
        AppDelegate(model: model, runtime: runtime, claudeMonitor: claudeMonitor)
    }
    app.delegate = delegate
    withExtendedLifetime(instanceLock) {
        app.run()
    }
} catch {
    fputs("Second Wind failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
