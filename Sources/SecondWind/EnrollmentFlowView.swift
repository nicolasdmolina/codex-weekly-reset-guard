import AppKit
import SwiftUI

/// Adding an account: pick the service, give the email, sign in in the browser, see the limits.
/// Every step after the service list shares one frame: the service tile at a fixed spot, the
/// step's words under it, and one primary action in the same bottom slot. Steps cross-fade, so
/// the tile stays put while its ring, badge and text change.
struct EnrollmentFlowView: View {
    @ObservedObject var model: GuardAppModel
    @ObservedObject var interface: GuardInterfaceModel
    let phase: EnrollmentPhase
    let isStaticRender: Bool
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            screen
                .id(screenKey)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(SW.Motion.easeOut(SW.Motion.standard, reduceMotion: reduceMotion || isStaticRender), value: screenKey)
    }

    /// Phases that look alike share a key, so a checking-to-connected change animates once.
    private var screenKey: String {
        switch phase {
        case .choose: "choose"
        case let .email(provider): "email-\(provider.rawValue)"
        case .waiting: "waiting"
        case .connected: "connected"
        case .problem: "problem"
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch phase {
        case .choose:
            ChooseServiceScreen(model: model, interface: interface)
        case let .email(provider):
            EmailScreen(model: model, provider: provider, isStaticRender: isStaticRender)
        case let .waiting(ref, checking):
            WaitingScreen(model: model, account: ref, isChecking: checking, isStaticRender: isStaticRender)
        case let .connected(ref):
            ConnectedScreen(model: model, interface: interface, account: ref, isStaticRender: isStaticRender, now: now)
        case let .problem(ref, state):
            ProblemScreen(model: model, account: ref, state: state, isStaticRender: isStaticRender)
        }
    }
}

// MARK: - Shared frame

/// The tile, the step's content and its actions, in the same places on every step.
private struct StepFrame<Content: View, Actions: View>: View {
    let provider: ProviderKind
    let tile: ServiceTile.State
    let isStaticRender: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ServiceTile(provider: provider, state: tile, isStaticRender: isStaticRender)
                .padding(.top, 44)
            content
                .padding(.top, SW.Space.lg + 2)
            Spacer(minLength: SW.Space.md)
            // A fixed slot: the primary button sits at the same height with or without a
            // text button under it.
            VStack(spacing: SW.Space.xs + 2) { actions }
                .frame(height: 60, alignment: .top)
                .padding(.bottom, SW.Space.md)
        }
        .padding(.horizontal, SW.Space.lg)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The one filled button a step offers, always full width in the bottom slot.
private struct PrimaryAction: View {
    let title: String
    var opensBrowser = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SW.Space.xs + 1) {
                Text(title)
                if opensBrowser {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10.5, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SWPrimaryButtonStyle(isLarge: true))
        .disabled(!isEnabled)
        .keyboardShortcut(.defaultAction)
    }
}

private struct StepTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One or two centred lines under a title. Emphasised runs (an email) read in primary text.
private struct StepMessage: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 12.5))
            .foregroundStyle(SW.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300)
            .padding(.top, SW.Space.xs + 2)
    }
}

private func emphasised(_ text: String) -> Text {
    Text(text).fontWeight(.semibold).foregroundStyle(SW.Palette.textPrimary)
}

// MARK: - Choose

private struct ChooseServiceScreen: View {
    @ObservedObject var model: GuardAppModel
    @ObservedObject var interface: GuardInterfaceModel

    var body: some View {
        let isFirstRun = !model.hasAccounts
        VStack(spacing: 0) {
            if isFirstRun {
                Spacer(minLength: SW.Space.lg)
                StepTitle(text: "Add your first account")
                    .padding(.bottom, SW.Space.lg)
            }
            VStack(spacing: 0) {
                ForEach(Array(ProviderKind.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { RowDivider().padding(.leading, 46) }
                    ProviderChoiceRow(
                        provider: provider,
                        detail: detail(for: provider),
                        isAvailable: isAvailable(provider)
                    ) {
                        model.chooseEnrollmentProvider(provider)
                    }
                }
            }
            .background(SW.Palette.surface, in: RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous)
                    .strokeBorder(SW.Palette.hairline)
            }
            Spacer(minLength: 0)
            if isFirstRun { Spacer(minLength: 0) }
        }
        .padding(.horizontal, SW.Space.lg)
        .padding(.top, isFirstRun ? 0 : SW.Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a service")
    }

    private func isAvailable(_ provider: ProviderKind) -> Bool {
        if model.isReadOnly { return false }
        if case .failed = interface.providerStates[provider] { return false }
        return true
    }

    private func detail(for provider: ProviderKind) -> String {
        if case .failed = interface.providerStates[provider] { return "Could not load" }
        return switch provider {
        case .codex: "Paid ChatGPT plan"
        case .claude: "Claude Pro or Max"
        }
    }
}

private struct ProviderChoiceRow: View {
    let provider: ProviderKind
    let detail: String
    let isAvailable: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SW.Space.md) {
                ServiceTile(provider: provider, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(SW.Palette.textPrimary)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SW.Palette.textSecondary)
                }
                Spacer(minLength: SW.Space.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .offset(x: isHovering && isAvailable ? 2 : 0)
            }
            .padding(.horizontal, SW.Space.md)
            .frame(height: 58)
            .background(SW.Palette.surfaceRaised.opacity(isHovering && isAvailable ? 0.55 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.5)
        .onHover { hovering in
            withAnimation(.easeOut(duration: SW.Motion.quick)) { isHovering = hovering }
        }
        .accessibilityLabel("\(provider.title), \(detail)")
        .accessibilityHint("Add a \(provider.title) account")
    }
}

/// Rows darken slightly while pressed, like a native list.
private struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 0.9 : 0))
    }
}

// MARK: - Email

private struct EmailScreen: View {
    @ObservedObject var model: GuardAppModel
    let provider: ProviderKind
    let isStaticRender: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        StepFrame(provider: provider, tile: .plain, isStaticRender: isStaticRender) {
            VStack(spacing: 0) {
                StepTitle(text: "Sign in with \(provider.signInAccountName)")
                VStack(alignment: .leading, spacing: SW.Space.xs + 2) {
                    Text("Email")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SW.Palette.textSecondary)
                    field
                    // The error row keeps its height, so nothing below it moves.
                    StatusLine(symbol: "exclamationmark.circle.fill", text: model.enrollmentError ?? " ", tone: .critical)
                        .opacity(model.enrollmentError == nil ? 0 : 1)
                        .accessibilityHidden(model.enrollmentError == nil)
                }
                .padding(.top, SW.Space.xl)
            }
        } actions: {
            PrimaryAction(
                title: model.isAddingProfile ? "Opening browser…" : "Continue in browser",
                opensBrowser: !model.isAddingProfile,
                isEnabled: model.canAdd(provider) && !model.isAddingProfile
            ) {
                model.addProfile()
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous)
        let hasError = model.enrollmentError != nil
        let isActive = isFocused || isStaticRender
        Group {
            if isStaticRender {
                Text(model.profileEmail.isEmpty ? "you@example.com" : model.profileEmail)
                    .foregroundStyle(model.profileEmail.isEmpty ? SW.Palette.textTertiary : SW.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(
                    "Email",
                    text: $model.profileEmail,
                    prompt: Text("you@example.com").foregroundStyle(SW.Palette.textTertiary)
                )
                .textFieldStyle(.plain)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .focused($isFocused)
                .onSubmit { model.addProfile() }
                .onChange(of: model.profileEmail) { _, _ in model.enrollmentError = nil }
                .onAppear { isFocused = true }
                .disabled(model.isAddingProfile)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, SW.Space.md - 2)
        .frame(height: 32)
        .background(SW.Palette.surface, in: shape)
        .overlay {
            shape.strokeBorder(
                hasError ? SW.Palette.critical : (isActive ? SW.Palette.accent : SW.Palette.fieldBorder),
                lineWidth: isActive || hasError ? 1.5 : 1
            )
        }
        .accessibilityLabel("\(provider.signInAccountName) email")
    }
}

// MARK: - Waiting

private struct WaitingScreen: View {
    @ObservedObject var model: GuardAppModel
    let account: AccountRef
    let isChecking: Bool
    let isStaticRender: Bool

    var body: some View {
        let url = isChecking ? nil : model.signInURL(for: account)
        StepFrame(provider: account.provider, tile: .waiting, isStaticRender: isStaticRender) {
            VStack(spacing: 0) {
                StepTitle(text: isChecking ? "Reading your limits" : "Finish in your browser")
                StepMessage(text: message)
            }
        } actions: {
            if let url {
                PrimaryAction(title: "Reopen in browser", opensBrowser: true) {
                    if !model.isPreview { NSWorkspace.shared.open(url) }
                }
                CopyLinkButton(url: url)
            }
        }
    }

    private var message: Text {
        let email = model.enrollment?.email ?? ""
        if isChecking { return Text("Signed in. One moment.") }
        if email.isEmpty { return Text("Sign in with the account you added.") }
        return Text("Sign in as ") + emphasised(email)
    }
}

private struct CopyLinkButton: View {
    let url: URL
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy link for another browser", systemImage: didCopy ? "checkmark" : "link")
                .labelStyle(TightLabelStyle())
                .contentTransition(.opacity)
        }
        .buttonStyle(SWQuietButtonStyle())
        .help("Paste into a private window to sign in without the browser's current account")
        .accessibilityLabel(didCopy ? "Link copied" : "Copy sign-in link")
    }
}

// MARK: - Problem

private struct ProblemScreen: View {
    @ObservedObject var model: GuardAppModel
    let account: AccountRef
    let state: SignInState
    let isStaticRender: Bool

    var body: some View {
        StepFrame(provider: account.provider, tile: .problem, isStaticRender: isStaticRender) {
            VStack(spacing: 0) {
                StepTitle(text: title)
                StepMessage(text: message)
            }
        } actions: {
            PrimaryAction(title: "Sign in again", opensBrowser: true) { model.retryEnrollmentSignIn() }
            if case let .wrongAccount(found?) = state, account.provider == .claude {
                Button("Watch \(found) instead") { model.adoptSignedInAccount(found) }
                    .buttonStyle(SWQuietButtonStyle())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if offersDifferentEmail {
                Button("Use a different email") { model.cancelEnrollment(returningTo: account.provider) }
                    .buttonStyle(SWQuietButtonStyle())
            }
        }
    }

    private var email: String { model.enrollment?.email ?? "" }

    private var offersDifferentEmail: Bool {
        switch state {
        case .wrongAccount, .noPlan: true
        default: false
        }
    }

    private var title: String {
        switch state {
        case .wrongAccount: "Wrong account"
        case .noPlan: "No Pro or Max plan"
        case .signedOut: "Sign-in didn't finish"
        default: "Couldn't connect"
        }
    }

    private var message: Text {
        switch state {
        case let .wrongAccount(found):
            let signedIn = found.map { Text("You signed in as ") + emphasised($0) + Text(". ") }
                ?? Text("That was a different account. ")
            guard !email.isEmpty else { return signedIn + Text("Switch accounts in your browser, then sign in again.") }
            return signedIn + Text("Switch to ") + emphasised(email) + Text(" in your browser, then sign in again.")
        case .noPlan:
            return (email.isEmpty ? Text("This account") : emphasised(email)) + Text(" has no Claude plan limits to watch.")
        case .signedOut:
            return Text("The browser page was closed or timed out.")
        case let .failed(reason):
            return Text(reason)
        case .waiting, .checking, .connected:
            return Text("")
        }
    }
}

// MARK: - Connected

private struct ConnectedScreen: View {
    @ObservedObject var model: GuardAppModel
    @ObservedObject var interface: GuardInterfaceModel
    let account: AccountRef
    let isStaticRender: Bool
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The meters fill from empty once, the moment the first reading arrives on screen.
    @State private var hasFilled = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var renameError: String?
    @State private var isSavingName = false
    @FocusState private var isNameFocused: Bool

    private var raw: String { account.id.uuidString.lowercased() }
    private var codex: GuardProfilePresentation? { model.profiles.first { $0.id == raw } }
    private var claude: ClaudeProfilePresentation? { model.claudeProfiles.first { $0.id == raw } }

    var body: some View {
        StepFrame(provider: account.provider, tile: .connected, isStaticRender: isStaticRender) {
            VStack(spacing: 0) {
                nameRow
                    .frame(height: 24)
                if let renameError {
                    StatusLine(symbol: "exclamationmark.circle.fill", text: renameError, tone: .critical)
                        .padding(.top, SW.Space.xxs)
                } else {
                    Text("Connected as \(identity)")
                        .font(.system(size: 12))
                        .foregroundStyle(SW.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, SW.Space.xxs)
                }
                limits
                    .padding(.top, SW.Space.lg + 2)
            }
        } actions: {
            PrimaryAction(title: "Done", isEnabled: !isSavingName) {
                if isRenaming { commitName() }
                if let ref = model.finishEnrollment() { interface.reveal(ref) }
            }
            Button("Add another account") { model.beginEnrollment() }
                .buttonStyle(SWQuietButtonStyle())
        }
        .onAppear {
            guard !hasFilled else { return }
            guard !isStaticRender, !reduceMotion else {
                hasFilled = true
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(240))
                withAnimation(SW.Motion.easeOut(0.9, reduceMotion: false)) { hasFilled = true }
            }
        }
    }

    private var name: String { codex?.displayName ?? claude?.displayName ?? account.provider.title }

    private var identity: String {
        let email = model.enrollment?.email ?? ""
        return email.isEmpty ? (codex?.accountHint ?? claude?.accountHint ?? "") : email
    }

    // MARK: Name

    @ViewBuilder
    private var nameRow: some View {
        if isRenaming {
            TextField("Account name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($isNameFocused)
                .onSubmit(commitName)
                .onExitCommand { isRenaming = false }
                .onChange(of: draftName) { _, value in
                    let limit = GuardInterfaceModel.maximumNameLength(for: account.provider)
                    if value.count > limit { draftName = String(value.prefix(limit)) }
                }
                .disabled(isSavingName)
                .frame(maxWidth: 220)
                .padding(.vertical, 1)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SW.Palette.accent).frame(height: 1.5).offset(y: 3)
                }
                .onAppear { isNameFocused = true }
                .accessibilityLabel("Account name")
        } else {
            HStack(spacing: SW.Space.xs + 2) {
                StepTitle(text: name)
                    .lineLimit(1)
                if let plan = claude?.planName {
                    Text(plan)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SW.Palette.textSecondary)
                        .padding(.horizontal, SW.Space.xs + 2)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(SW.Palette.fieldBorder))
                }
                if !isStaticRender && !model.isReadOnly {
                    Button {
                        draftName = name
                        renameError = nil
                        isRenaming = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SWIconButtonStyle())
                    .help("Rename")
                    .accessibilityLabel("Rename \(name)")
                }
            }
        }
    }

    private func commitName() {
        let next = GuardInterfaceModel.normalizedName(draftName)
        guard next.contains(where: { $0.isLetter || $0.isNumber }) else {
            renameError = "Enter a name with at least one letter or number."
            return
        }
        guard next != name else {
            isRenaming = false
            return
        }
        if model.isPreview {
            if let index = model.profiles.firstIndex(where: { $0.id == raw }) { model.profiles[index].displayName = next }
            if let index = model.claudeProfiles.firstIndex(where: { $0.id == raw }) { model.claudeProfiles[index].displayName = next }
            isRenaming = false
            return
        }
        guard let rename = interface.renameAccount else {
            isRenaming = false
            return
        }
        isSavingName = true
        Task { @MainActor in
            defer { isSavingName = false }
            do {
                try await rename(account, next)
                renameError = nil
                isRenaming = false
            } catch {
                renameError = "Could not rename. \((error as? LocalizedError)?.errorDescription ?? "Try again.")"
            }
        }
    }

    // MARK: Limits

    private var quota: AccountQuotaDisplay? {
        if let codex { return QuotaDisplayBuilder.codex(codex, now: now) }
        if let claude { return QuotaDisplayBuilder.claude(claude, now: now) }
        return nil
    }

    /// Before the fill, each meter starts empty in whichever convention the user reads.
    private func displayed(_ window: WindowDisplay) -> WindowDisplay {
        guard !hasFilled, window.remaining != nil else { return window }
        return WindowDisplay(
            id: window.id,
            label: window.label,
            remaining: interface.preferences.quota == .remaining ? 0 : 100,
            resetsAt: window.resetsAt,
            state: window.state,
            level: .ok,
            alertLine: window.alertLine
        )
    }

    @ViewBuilder
    private var limits: some View {
        VStack(spacing: 0) {
            VStack(spacing: SW.Space.sm) {
                if let quota, !quota.windows.isEmpty {
                    ForEach(quota.windows) { window in
                        WindowRow(
                            window: displayed(window),
                            convention: interface.preferences.quota,
                            resetStyle: interface.preferences.resetTimes,
                            now: now,
                            isStatic: isStaticRender,
                            onToggleStyle: { interface.toggleResetTimeStyle() }
                        )
                    }
                } else {
                    StatusLine(symbol: "clock", text: "Limits appear after the first check.", tone: .neutral)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(SW.Space.md)
            if let codex {
                RowDivider()
                HStack(spacing: SW.Space.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-redeem at 3% left")
                            .font(.system(size: 12, weight: .medium))
                        if let saved = savedResets(quota?.inventory) {
                            Text(saved)
                                .font(.system(size: 11))
                                .foregroundStyle(SW.Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: SW.Space.sm)
                    if isStaticRender {
                        StaticToggle(isOn: codex.autoResetEnabled, label: "Auto-redeem")
                    } else {
                        Toggle("Auto-redeem", isOn: Binding(
                            get: { codex.autoResetEnabled },
                            set: { model.setAutoReset(profileID: codex.id, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Redeem a saved reset after two weekly readings at or below 3% left")
                    }
                }
                .padding(.horizontal, SW.Space.md)
                .padding(.vertical, SW.Space.sm + 2)
            }
        }
        .background(SW.Palette.surface, in: RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous)
                .strokeBorder(SW.Palette.hairline)
        }
    }

    private func savedResets(_ inventory: InventoryDisplay?) -> String? {
        guard case let .known(count, _, _, _, _)? = inventory else { return nil }
        return switch count {
        case 0: "No saved resets yet"
        case 1: "1 saved reset"
        default: "\(count) saved resets"
        }
    }
}

// MARK: - Service tile

/// A neutral tile with the service's symbol. Progress circles it; results ride on a badge.
struct ServiceTile: View {
    enum State: Equatable { case plain, waiting, problem, connected }

    let provider: ProviderKind
    var size: CGFloat = 52
    var state: State = .plain
    var isStaticRender = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var badgeShown = false

    init(provider: ProviderKind, size: CGFloat = 52, state: State = .plain, isStaticRender: Bool = false) {
        self.provider = provider
        self.size = size
        self.state = state
        self.isStaticRender = isStaticRender
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(SW.Palette.surfaceRaised)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(SW.Palette.hairline)
            }
            .overlay {
                Image(systemName: provider.glyph)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(SW.Palette.textPrimary)
            }
            .frame(width: size, height: size)
            // Drawn over the layout, so the tile sits in the same place with or without it.
            .overlay {
                if state == .waiting {
                    SignInRing(diameter: size + 32, isStatic: isStaticRender)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if state == .connected || state == .problem {
                    badge
                        .offset(x: size * 0.14, y: size * 0.14)
                        .scaleEffect(isBadgeVisible ? 1 : 0.3)
                        .opacity(isBadgeVisible ? 1 : 0)
                }
            }
            .onAppear {
                guard !isStaticRender, !reduceMotion, state == .connected else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.62).delay(0.12)) { badgeShown = true }
            }
            .accessibilityHidden(true)
    }

    /// Only the success badge pops in; a problem badge is simply there.
    private var isBadgeVisible: Bool {
        state != .connected || badgeShown || isStaticRender || reduceMotion
    }

    private var badge: some View {
        let diameter = max(16, size * 0.4)
        let isGood = state == .connected
        return Circle()
            .fill(isGood ? SW.Palette.accent : SW.Palette.critical)
            .overlay {
                Image(systemName: isGood ? "checkmark" : "exclamationmark")
                    .font(.system(size: diameter * 0.48, weight: .heavy))
                    .foregroundStyle(SW.Palette.onAccent)
            }
            .frame(width: diameter, height: diameter)
            .padding(2.5)
            .background(SW.Palette.canvas, in: Circle())
    }
}

/// A slow accent arc circling the service tile while the browser has the user.
private struct SignInRing: View {
    let diameter: CGFloat
    let isStatic: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(SW.Palette.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.24)
                .stroke(SW.Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(isSpinning ? 270 : -90))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !isStatic, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { isSpinning = true }
        }
        .accessibilityHidden(true)
    }
}
