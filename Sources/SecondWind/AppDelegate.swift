import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: GuardAppModel
    /// Popover UI state and the user actions the app wires to the runtimes.
    let interface: GuardInterfaceModel
    var antigravity: AntigravityMonitor?
    var finishQuotaUpdates: (() async -> Void)?
    var onPopoverOpen: (() -> Void)?
    private let runtime: GuardRuntimeController?
    private let claudeMonitor: ClaudeMonitorController?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var isFinishingTermination = false
    private var startupTask: Task<Void, Never>?
    private var inspectionWindow: NSWindow?
    /// A request to open the popover that arrived before the status item existed.
    private var wantsPopover = false

    init(
        model: GuardAppModel,
        runtime: GuardRuntimeController? = nil,
        claudeMonitor: ClaudeMonitorController? = nil,
        interface: GuardInterfaceModel? = nil
    ) {
        self.model = model
        self.runtime = runtime
        self.claudeMonitor = claudeMonitor
        self.interface = interface
            ?? (model.isPreview ? PreviewFixtures.interface(for: model) : .live(isReadOnly: model.isReadOnly))
        super.init()
        // Attached before launch finishes, so a notification click that arrives first still resolves.
        self.interface.attach(model)
        // The browser takes focus during sign-in and the transient popover closes. When the
        // sign-in settles, bring Second Wind back in front with the result.
        model.onSignInSettled = { [weak self] account, inFlow in
            guard let self, !self.model.isPreview else { return }
            // After the snapshot that settled it has been applied, never inside it.
            DispatchQueue.main.async {
                if inFlow { self.showPopover() } else { self.reveal(account) }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.isPreview {
            showInspectionWindow()
            return
        }
        if model.isReadOnly {
            showInspectionWindow()
        } else {
            configureStatusItem()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        startProviders()
    }

    /// Codex and Claude start independently: one provider's unreadable store or failed start
    /// never keeps the other from loading, and the failure stays on screen with its reason.
    private func startProviders() {
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let antigravity { antigravity.start() } else { interface.providerDidLoad(.antigravity) }
            async let codexCount = startCodex()
            async let claudeCount = startClaude()
            let counts = await (codexCount, claudeCount)
            guard !Task.isCancelled else { return }
            if !model.isReadOnly, interface.allProvidersLoaded, counts.0 == 0, counts.1 == 0,
               model.antigravity == nil, !popover.isShown {
                showPopover()
            }
        }
    }

    private func startCodex() async -> Int? {
        guard let runtime else {
            interface.providerDidLoad(.codex)
            return 0
        }
        do {
            let snapshot = try await runtime.start()
            interface.providerDidLoad(.codex)
            return snapshot.profiles.count
        } catch {
            guard !Task.isCancelled else { return nil }
            interface.providerDidFail(.codex, reason: error.localizedDescription)
            return nil
        }
    }

    private func startClaude() async -> Int? {
        guard let claudeMonitor else {
            interface.providerDidLoad(.claude)
            return 0
        }
        do {
            try await claudeMonitor.start()
            interface.providerDidLoad(.claude)
            return await claudeMonitor.snapshot().profiles.count
        } catch {
            guard !Task.isCancelled else { return nil }
            interface.providerDidFail(.claude, reason: error.localizedDescription)
            return nil
        }
    }

    private func configureStatusItem() {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: SW.Size.popoverWidth, height: SW.Size.popoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: GuardPopoverView(model: model, interface: interface)
        )

        Publishers.Merge(model.objectWillChange, interface.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        // Ages and passed reset times change with the clock, not only with new snapshots.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        updateStatusItem()

        if wantsPopover {
            wantsPopover = false
            showPopover()
        }
    }

    private func showInspectionWindow() {
        // Both inspection modes use the real controls in a normal accessible window. Only the
        // separately configured read-only diagnostic starts account services; previews do not.
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SW.Size.popoverWidth, height: SW.Size.popoverHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.isPreview ? "Second Wind Preview" : "Second Wind Diagnostics"
        window.contentViewController = NSHostingController(
            rootView: GuardPopoverView(model: model, interface: interface)
        )
        window.isReleasedWhenClosed = false
        window.center()
        inspectionWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Navigation

    /// Opens the popover on one account. Safe on a cold start from a notification:
    /// the popover opens once the status item exists, and the account is scrolled to and
    /// highlighted once its provider has loaded. A removed account or an unloaded provider
    /// shows a notice instead.
    func reveal(_ target: AccountRef) {
        // An account alert outranks an add-account flow that has not started a sign-in.
        if model.enrollment?.hasStartedSignIn == false { model.enrollment = nil }
        showPopover()
        interface.reveal(target)
    }

    /// Opens the popover without choosing an account, for notices about the app itself.
    func showPopover() {
        if let inspectionWindow {
            inspectionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let button = statusItem?.button else {
            wantsPopover = true
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            onPopoverOpen?()
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model.isPreview || model.isReadOnly
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !isFinishingTermination else { return .terminateLater }
        isFinishingTermination = true
        startupTask?.cancel()
        antigravity?.stop()
        Task {
            await claudeMonitor?.stop()
            await runtime.stop()
            await startupTask?.value
            startupTask = nil
            await finishQuotaUpdates?()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDidWake() {
        model.checkNow()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let summary = PopoverSummary.make(model: model, interface: interface, now: Date())
        let image = NSImage(
            systemSymbolName: summary.showsAttentionIcon ? "exclamationmark.triangle" : "wind",
            accessibilityDescription: "Second Wind"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        // The icon alone when the user keeps the menu bar compact; the tooltip and VoiceOver
        // value below still carry the figure.
        if let title = summary.menuBarTitle, interface.preferences.showsMenuBarPercent {
            // An unconfirmed figure is dimmed rather than hidden: it is still the best number
            // available, but it does not claim to be current.
            // A confident figure keeps the system's own title colour, which follows highlight and
            // menu bar vibrancy; only the dimmed state sets a colour.
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
            if !summary.isConfident { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            button.attributedTitle = NSAttributedString(string: " \(title)", attributes: attributes)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = summary.tooltip
        button.setAccessibilityLabel("Second Wind")
        button.setAccessibilityValue(summary.accessibilityValue)
    }
}
