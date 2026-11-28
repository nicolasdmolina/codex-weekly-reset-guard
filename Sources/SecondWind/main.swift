import AppKit
import SecondWindCore
import Foundation

do {
    // Parsing must complete before constructing locks, runtimes, or NSApplication. In
    // particular, an invalid preview name must never fall through to production mode.
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command: GuardLaunchCommand
    do {
        command = try GuardCommandLine.parse(
            arguments,
            bundledPreviewKind: Bundle.main.object(forInfoDictionaryKey: "GuardPreviewKind")
                .map { String(describing: $0) },
            bundledDiagnosticDirectory: Bundle.main.object(forInfoDictionaryKey: "GuardDiagnosticSupportDirectory")
                .map { String(describing: $0) }
        )
    } catch where arguments.first == "--preflight" {
        exit(PreflightCommandLine.reportUsageError(error))
    }

    // Read-only: no lock, migration, app-server, or NSApplication.
    if case let .preflight(invocation) = command {
        exit(PreflightCommandLine.execute(invocation))
    }

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
    case .renderPreview, .renderAllPreviews, .selfTest, .doctor, .preflight:
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
    let services = MainActor.assumeIsolated {
        runtimeConfiguration.map { configuration in
            let alerts = makeAlertRouter(configuration: configuration)
            let codex = makeGuardRuntimeController(model: model, configuration: configuration, alerts: alerts)
            let claude = makeClaudeMonitor(model: model, configuration: ClaudeMonitorConfiguration(
                isReadOnly: configuration.operationMode == .readOnly,
                executableURL: ProcessClaudeCommandRunner.defaultExecutableURL,
                applicationSupportDirectory: configuration.applicationSupportDirectory
            ), alerts: alerts)
            return (codex: codex, claude: claude, alerts: alerts)
        }
    }
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated {
        let delegate = AppDelegate(model: model, runtime: services?.codex, claudeMonitor: services?.claude)
        guard let services, let configuration = runtimeConfiguration else { return delegate }
        model.onCheckNow = { [weak delegate] in
            delegate?.antigravity?.checkNow()
            Task { _ = await services.codex.checkNow() }
            Task { await services.claude.checkNow() }
        }
        if configuration.operationMode == .production {
            connectLiveFeatures(model: model, delegate: delegate, codex: services.codex, claude: services.claude,
                                alerts: services.alerts, supportDirectory: configuration.applicationSupportDirectory)
        }
        return delegate
    }
    app.delegate = delegate
    let responder = MainActor.assumeIsolated { () -> AlertResponder? in
        guard command == .production, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return AlertResponder.install { [weak delegate] target in
            if let target { delegate?.reveal(target) } else { delegate?.showPopover() }
        }
    }
    withExtendedLifetime((instanceLock, responder)) {
        app.run()
    }
} catch {
    fputs("Second Wind failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
