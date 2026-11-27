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

    init(_ kind: PreviewKind, inWindow: Bool = true) async {
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
        if inWindow { await show() }
    }

    /// Waits for a condition instead of a fixed delay, so a busy parallel run cannot fake a failure.
    @discardableResult
    func waitUntil(_ timeout: Double = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    /// Puts the view in its window, as opening the popover does.
    func show() async {
        window.contentView = host
        window.orderFrontRegardless()
        await settle()
    }

    var scrollOffset: CGFloat? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let scroll = find(subview) { return scroll } }
            return nil
        }
        return find(host)?.contentView.bounds.origin.y
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

// One window at a time: each test makes its off-screen window key to type, and two running at
// once would take focus from each other.
@Suite(.serialized, .enabled(if: nativeQA))
@MainActor
struct NativePopoverTests {
    @Test func nativeRenameFieldTypesAndSubmitsThroughAppKit() async {
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

    @Test func nativeSettingsAndConventionsRender() async {
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

    @Test func nativeRevealScrollsHighlightsAndFades() async {
        let harness = await NativeHarness(.reveal)
        defer { harness.close() }
        let work = AccountRef(provider: .codex, id: PreviewFixtures.ID.work)
        #expect(harness.interface.highlighted == work)
        #expect(await harness.waitUntil { harness.interface.scrollTarget == nil }, "The scroll view consumed the request")
        harness.snapshot("native-06-reveal")
        #expect(await harness.waitUntil(GuardInterfaceModel.highlightDuration + 3) { harness.interface.highlighted == nil },
                "The highlight fades on its own")
        harness.snapshot("native-07-reveal-faded")
    }

    @Test func nativeRevealOfAClosedPopoverScrollsOnceItOpens() async {
        // Production order: the popover's view exists before the click, the click sets the target
        // while the popover is closed, and the popover opens afterwards.
        let harness = await NativeHarness(.freshness, inWindow: false)
        defer { harness.close() }
        let studio = AccountRef(provider: .claude, id: PreviewFixtures.ID.studio)
        let personal = AccountRef(provider: .codex, id: PreviewFixtures.ID.personal)
        harness.interface.reveal(studio)
        await harness.settle()
        #expect(harness.interface.highlighted == studio)
        #expect(harness.interface.scrollTarget == studio, "A closed popover holds the request")
        await harness.show()
        #expect(await harness.waitUntil { harness.interface.scrollTarget == nil }, "The opened popover consumed the request")
        let scrolled = await harness.waitUntil { (harness.scrollOffset ?? 0) > 0 }
        #expect(scrolled, "The list scrolled toward the bottom account, offset \(harness.scrollOffset ?? -1)")
        harness.snapshot("native-08-reveal-after-open")

        // While open, a second click scrolls back up.
        let offset = harness.scrollOffset ?? 0
        harness.interface.reveal(personal)
        let up = await harness.waitUntil { (harness.scrollOffset ?? 0) < offset }
        #expect(up, "An open popover scrolls on a new request, offset \(harness.scrollOffset ?? -1) from \(offset)")
        await harness.waitUntil { harness.interface.scrollTarget == nil }

        // Closed again: the request waits for the next opening.
        let top = harness.scrollOffset ?? 0
        harness.window.contentView = nil
        await harness.settle()
        harness.interface.reveal(studio)
        await harness.settle()
        await harness.show()
        let reopened = await harness.waitUntil { (harness.scrollOffset ?? 0) > top }
        #expect(reopened, "Reopening scrolls to the new target, offset \(harness.scrollOffset ?? -1) from \(top)")
        #expect(await harness.waitUntil { harness.interface.scrollTarget == nil })
    }

    @Test func nativeEnrollmentTypesTheEmailAndContinuesOnReturn() async {
        let harness = await NativeHarness(.onboarding)
        defer { harness.close() }
        harness.snapshot("native-09-enroll-choose")
        #expect(harness.textField() == nil, "The service list has no field")

        // Rows are SwiftUI buttons with no accessibility tree here; the row press calls this.
        harness.model.chooseEnrollmentProvider(.codex)
        await harness.settle()
        #expect(harness.textField() != nil, "The email step shows a real field")
        await harness.pressKey("\u{1b}", keyCode: 53)
        #expect(harness.model.enrollmentPhase == .choose, "Escape goes back to the service list")

        harness.model.chooseEnrollmentProvider(.codex)
        await harness.settle()
        await harness.type("nicky@")
        await harness.pressKey("\r", keyCode: 36)
        #expect(harness.model.enrollmentError != nil, "Return checks the address")
        #expect(harness.model.enrollmentPhase == .email(.codex))
        harness.snapshot("native-10-enroll-email-error")

        await harness.type("nicky@gmail.com")
        #expect(harness.model.enrollmentError == nil, "Editing clears the error")
        await harness.pressKey("\r", keyCode: 36)
        let waiting = await harness.waitUntil {
            if case .waiting? = harness.model.enrollmentPhase { true } else { false }
        }
        #expect(waiting, "Return continues to the browser sign-in")
        harness.snapshot("native-11-enroll-waiting")

        let connected = await harness.waitUntil(6) {
            if case .connected? = harness.model.enrollmentPhase { true } else { false }
        }
        #expect(connected, "The preview's synthetic sign-in finishes")
        await harness.settle(1.4)
        #expect(harness.model.profiles.first?.displayName == "Personal")
        harness.snapshot("native-12-enroll-connected")

        await harness.pressKey("\r", keyCode: 36)
        #expect(harness.model.enrollmentPhase == nil, "Return on the result closes the flow")
        #expect(harness.interface.highlighted != nil, "The new account is highlighted in the list")
        harness.snapshot("native-13-enroll-done")
    }
}
