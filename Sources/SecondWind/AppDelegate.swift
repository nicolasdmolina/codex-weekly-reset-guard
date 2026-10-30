import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: GuardAppModel
    private let runtime: GuardRuntimeController?
    private let claudeMonitor: ClaudeMonitorController?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var isFinishingTermination = false
    private var startupTask: Task<Void, Never>?
    private var inspectionWindow: NSWindow?

    init(model: GuardAppModel, runtime: GuardRuntimeController? = nil, claudeMonitor: ClaudeMonitorController? = nil) {
        self.model = model
        self.runtime = runtime
        self.claudeMonitor = claudeMonitor
        super.init()
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

        if let runtime {
            startupTask = Task {
                do {
                    let snapshot = try await runtime.start()
                    var claudeCount = 0
                    if let claudeMonitor {
                        do {
                            try await claudeMonitor.start()
                            claudeCount = await claudeMonitor.snapshot().profiles.count
                        } catch {
                            model.banner = "Claude monitoring could not start: \(error.localizedDescription)"
                        }
                    }
                    if !model.isReadOnly, snapshot.profiles.isEmpty, claudeCount == 0, !popover.isShown,
                       let button = statusItem.button {
                        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                        popover.contentViewController?.view.window?.makeKey()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        model.banner = "Second Wind could not start: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func configureStatusItem() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: SW.Size.popoverWidth, height: SW.Size.popoverHeight)
        popover.contentViewController = NSHostingController(rootView: GuardPopoverView(model: model))

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        updateStatusItem()

    }

    private func showInspectionWindow() {
        // Both inspection modes use the real controls in a normal accessible window. Only the
        // separately configured read-only diagnostic starts account services; previews do not.
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.isPreview ? "Second Wind Preview" : "Second Wind Diagnostics"
        window.contentViewController = NSHostingController(rootView: GuardPopoverView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        inspectionWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model.isPreview || model.isReadOnly
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !isFinishingTermination else { return .terminateLater }
        isFinishingTermination = true
        startupTask?.cancel()
        Task {
            await claudeMonitor?.stop()
            await runtime.stop()
            await startupTask?.value
            startupTask = nil
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
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: model.hasAttention ? "exclamationmark.triangle" : "wind",
            accessibilityDescription: "Second Wind"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        if let minimum = model.minimumRemainingPercent {
            button.title = " \(Int(minimum.rounded(.down)))%"
            button.toolTip = model.hasAttention
                ? "Second Wind: an account needs attention"
                : "Second Wind: lowest headroom \(Int(minimum.rounded(.down)))%"
        } else {
            button.title = ""
            button.toolTip = model.hasAccounts ? "Second Wind: connecting accounts" : "Second Wind: add an account"
        }
    }
}
