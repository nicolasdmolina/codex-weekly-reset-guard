import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SecondWind

// Drives the real popover, with its AppKit-backed controls, in an off-screen window: text goes
// through the real field editor and keys through the window, and snapshots show what AppKit
// draws. SwiftUI builds no accessibility tree without an assistive client, so button presses are
// covered by the live preview run instead. Opt-in because it needs a window server:
//   SECOND_WIND_NATIVE_QA=1 [SECOND_WIND_NATIVE_QA_OUT=<dir>] ./scripts/test.sh
// Synthetic previews only; no account, network or notification is touched.

private let nativeQA = ProcessInfo.processInfo.environment["SECOND_WIND_NATIVE_QA"] != nil

@MainActor
private final class NativeHarness {
    let model: GuardAppModel
    let interface: GuardInterfaceModel
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init(_ kind: PreviewKind) async {
        _ = NSApplication.shared
        model = PreviewFixtures.model(for: kind)
        interface = PreviewFixtures.interface(for: model)
        host = NSHostingView(rootView: AnyView(
            GuardPopoverView(model: model, interface: interface).environment(\.colorScheme, .dark)
        ))
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: SW.Size.popoverWidth, height: SW.Size.popoverHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        await settle()
    }

    /// Suspends rather than spinning the run loop, so SwiftUI updates and main-actor tasks run.
    func settle(_ seconds: Double = 0.35) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func close() { window.close() }

    func textField() -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for subview in view.subviews { if let field = find(subview) { return field } }
            return nil
        }
        return find(host)
    }

    /// Replaces the field's text through the field editor, the path real typing takes.
    func type(_ text: String) async {
        guard let field = textField() else {
            Issue.record("No editable text field on screen")
            return
        }
        window.makeKey()
        window.makeFirstResponder(field)
        await settle(0.1)
        guard let editor = field.currentEditor() as? NSTextView else {
            Issue.record("The text field did not take focus")
            return
        }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        await settle()
    }

    func pressKey(_ characters: String, keyCode: UInt16) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )
            if let event { window.sendEvent(event) }
        }
        await settle()
    }

    func snapshot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SECOND_WIND_NATIVE_QA_OUT"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@Test(.enabled(if: nativeQA)) @MainActor func nativeRenameFieldTypesAndSubmitsThroughAppKit() async {
    let harness = await NativeHarness(.healthy)
    defer { harness.close() }
    let personal = AccountRef(provider: .codex, id: PreviewFixtures.ID.personal)
    let work = AccountRef(provider: .codex, id: PreviewFixtures.ID.work)
    harness.snapshot("native-01-healthy")
    #expect(harness.textField() == nil)

    // The row menu's Rename item calls this; menus run a modal loop, so the harness starts here.
    harness.interface.beginRename(work, currentName: "Work")
    await harness.settle()
    #expect(harness.textField()?.stringValue == "Work", "The real field opens with the current name")
    await harness.type("Client   work")
    #expect(harness.interface.draftName == "Client   work", "Field editor input reaches the draft")
    await harness.pressKey("\r", keyCode: 36)
    #expect(harness.interface.accountFeedback[work] == .failure("Preview only. Names change in the installed app."))
    #expect(harness.model.profiles[1].displayName == "Work", "A preview never renames")
    harness.snapshot("native-02-rename-submitted")

    harness.interface.cancelEditing()
    harness.interface.toggleInventoryDetail(personal)
    harness.interface.confirmRemoval(personal)
    await harness.settle()
    #expect(harness.textField() == nil)
    harness.snapshot("native-03-remove-confirm-expiry-list")
}

@Test(.enabled(if: nativeQA)) @MainActor func nativeSettingsAndConventionsRender() async {
    let harness = await NativeHarness(.overview)
    defer { harness.close() }
    harness.interface.showSettings()
    await harness.settle()
    harness.snapshot("native-04-settings")
    harness.interface.preferences = DisplayPreferences(quota: .used, resetTimes: .exact)
    harness.interface.showAccounts()
    await harness.settle()
    harness.snapshot("native-05-used-clock")
}

@Test(.enabled(if: nativeQA)) @MainActor func nativeRevealScrollsHighlightsAndFades() async {
    let harness = await NativeHarness(.reveal)
    defer { harness.close() }
    let work = AccountRef(provider: .codex, id: PreviewFixtures.ID.work)
    #expect(harness.interface.highlighted == work)
    #expect(harness.interface.scrollTarget == nil, "The scroll view consumed the scroll request")
    harness.snapshot("native-06-reveal")
    await harness.settle(GuardInterfaceModel.highlightDuration + 0.6)
    #expect(harness.interface.highlighted == nil, "The highlight fades on its own")
    harness.snapshot("native-07-reveal-faded")
}
