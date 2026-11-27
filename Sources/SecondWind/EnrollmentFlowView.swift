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
        ZStack(alignment: .top) {
            screen
                .id(screenKey)
                .transition(stepTransition)
            // One tile for every step after the service list. It never fades with the words
            // around it; only its outline and badge change.
            if let tile {
                ServiceTile(provider: tile.provider, state: tile.state, isStaticRender: isStaticRender)
                    .padding(.top, stepTileTop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(SW.Motion.easeOut(SW.Motion.standard, reduceMotion: reduceMotion || isStaticRender), value: screenKey)
    }

    private var tile: (provider: ProviderKind, state: ServiceTile.State)? {
        switch phase {
        case .choose: nil
        case let .waiting(provider, _, _): (provider, .waiting)
        case let .problem(provider, _, _): (provider, .problem)
        case let .connected(ref): (ref.provider, .connected)
        }
    }

    /// The old words clear quickly and the new ones settle in just after, so two titles are
    /// never legible on top of each other.
    private var stepTransition: AnyTransition {
        guard !reduceMotion, !isStaticRender else { return .identity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }

    /// Phases that look alike share a key, so a checking-to-connected change animates once.
    private var screenKey: String {
        switch phase {
        case .choose: "choose"
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
        case let .waiting(provider, ref, checking):
            WaitingScreen(model: model, provider: provider, account: ref, isChecking: checking)
        case let .connected(ref):
            ConnectedScreen(model: model, interface: interface, account: ref, isStaticRender: isStaticRender, now: now)
        case let .problem(provider, ref, state):
            ProblemScreen(model: model, interface: interface, provider: provider, account: ref, state: state)
        }
    }
}

// MARK: - Shared frame

/// The tile, the step's content and its actions, in the same places on every step.
/// Where the shared service tile sits, measured from the top of the flow.
private let stepTileTop: CGFloat = 60

private struct StepFrame<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            // The flow draws the tile above every step; this keeps its place.
            Color.clear
                .frame(height: ServiceTile.defaultSize)
                .padding(.top, stepTileTop)
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

/// A full-width bordered button for the bottom slot when the step's main action is not the
/// one thing to do, as while waiting on the browser.
private struct SecondaryAction: View {
    let title: String
    var opensBrowser = false
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
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FlowBorderedButtonStyle())
    }
}

private struct FlowBorderedButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
        configuration.label
            .foregroundStyle(SW.Palette.textPrimary)
            .frame(height: 30)
            .background(SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 1 : (isHovering ? 0.8 : 0.5)), in: shape)
            .overlay(shape.strokeBorder(SW.Palette.fieldBorder))
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }
}

/// The step's one other action, under the primary button: plain words that still read as a
/// control, with a pill on hover.
struct FlowLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? SW.Palette.textPrimary : SW.Palette.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, SW.Space.sm + 2)
            .frame(height: 24)
            .background(
                SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 1 : (isHovering ? 0.7 : 0)),
                in: RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

private struct StepTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
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
                    if index > 0 { RowDivider().padding(.leading, 58) }
                    ProviderChoiceRow(
                        provider: provider,
                        detail: detail(for: provider),
                        isAvailable: isAvailable(provider)
                    ) {
                        model.startEnrollment(provider)
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
        if case .failed = interface.providerStates[provider] { return false }
        return model.canAdd(provider) && !model.isAddingProfile
    }

    private func detail(for provider: ProviderKind) -> String {
        if case .failed = interface.providerStates[provider] { return "Could not load" }
        return switch provider {
        case .codex: "Sign in with ChatGPT"
        case .claude: "Sign in with Claude Pro or Max"
        }
    }
}

/// One service. Choosing it opens that service's sign-in in the browser, so the row ends in
/// the same arrow the browser buttons use.
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
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering && isAvailable ? SW.Palette.textSecondary : SW.Palette.textTertiary)
                    .offset(x: isHovering && isAvailable ? 1.5 : 0, y: isHovering && isAvailable ? -1.5 : 0)
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
        .accessibilityLabel("Add a \(provider.title) account")
        .accessibilityHint("Opens the \(provider.signInAccountName) sign-in in your browser")
    }
}

/// Rows darken slightly while pressed, like a native list.
private struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 0.9 : 0))
    }
}

// MARK: - Waiting

private struct WaitingScreen: View {
    @ObservedObject var model: GuardAppModel
    let provider: ProviderKind
    /// Nil while the new account is still being saved.
    let account: AccountRef?
    let isChecking: Bool

    var body: some View {
        let url = isChecking ? nil : account.flatMap { model.signInURL(for: $0) }
        StepFrame {
            VStack(spacing: 0) {
                StepTitle(text: title)
                StepMessage(text: Text(message))
            }
        } actions: {
            if let url {
                // The travelling outline is the only moving teal while the browser has the user.
                SecondaryAction(title: "Reopen in browser", opensBrowser: true) {
                    if !model.isPreview { NSWorkspace.shared.open(url) }
                }
                CopyLinkButton(url: url)
            }
        }
    }

    private var title: String {
        if isChecking { return "Reading your limits" }
        return account == nil ? "Opening your browser" : "Finish in your browser"
    }

    private var message: String {
        if isChecking { return "Signed in. One moment." }
        return "Sign in to \(provider.signInAccountName) with the account you want to watch."
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
            Text(didCopy ? "Link copied" : "Copy link for another browser")
                .contentTransition(.opacity)
        }
        .buttonStyle(FlowLinkButtonStyle())
        .help("Paste into a private window to sign in without the browser's current account")
        .accessibilityLabel(didCopy ? "Link copied" : "Copy sign-in link")
    }
}

// MARK: - Problem

private struct ProblemScreen: View {
    @ObservedObject var model: GuardAppModel
    @ObservedObject var interface: GuardInterfaceModel
    let provider: ProviderKind
    /// Nil when the new account could not even be saved.
    let account: AccountRef?
    let state: SignInState

    var body: some View {
        StepFrame {
            VStack(spacing: 0) {
                StepTitle(text: title)
                StepMessage(text: message)
            }
        } actions: {
            if readFailedAfterSignIn {
                // Signed in, but the first reading failed: read again rather than sign in again.
                PrimaryAction(title: "Check again") { model.checkNow() }
                Button("Finish and retry later") {
                    if let ref = model.finishEnrollment() { interface.reveal(ref) }
                }
                .buttonStyle(FlowLinkButtonStyle())
            } else {
                PrimaryAction(title: "Try again", opensBrowser: account != nil) { model.retryEnrollment() }
            }
        }
    }

    /// Codex reports a failed check separately from a failed sign-in; the account keeps
    /// checking on its own.
    private var readFailedAfterSignIn: Bool {
        guard provider == .codex, account != nil, case .failed = state else { return false }
        return model.enrollment?.startFailure == nil
    }

    private var title: String {
        switch state {
        case .alreadyAdded: "Already in Second Wind"
        case .wrongAccount: "Wrong account"
        case .noPlan: "No Pro or Max plan"
        case .signedOut: "Sign-in didn't finish"
        default: "Couldn't connect"
        }
    }

    private var message: Text {
        switch state {
        case let .alreadyAdded(found):
            let who = found.map(emphasised) ?? Text("That account")
            return who + Text(" is already being watched. Switch to another account in your browser, then try again.")
        case let .wrongAccount(found):
            let signedIn = found.map { Text("You signed in as ") + emphasised($0) + Text(".") }
                ?? Text("That was a different account.")
            return signedIn + Text(" Switch accounts in your browser, then try again.")
        case .noPlan:
            return Text("That Claude account has no Pro or Max plan, so there are no limits to watch. Sign in with another account.")
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
        StepFrame {
            VStack(spacing: 0) {
                nameRow
                    .frame(height: 24)
                if let renameError {
                    StatusLine(symbol: "exclamationmark.circle.fill", text: renameError, tone: .critical)
                        .padding(.top, SW.Space.xxs)
                } else {
                    (Text("Connected as ") + emphasised(identity) + Text(plan.map { " · \($0)" } ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(SW.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, SW.Space.xxs + 1)
                }
                limits
                    .padding(.top, SW.Space.lg + 2)
            }
        } actions: {
            PrimaryAction(title: "Done", isEnabled: !isSavingName) {
                if isRenaming { commitName() }
                if let ref = model.finishEnrollment() { interface.reveal(ref) }
            }
            AddAccountMenu(model: model, title: "Add another account", isStaticRender: isStaticRender)
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
    private var plan: String? { codex?.planName ?? claude?.planName }

    private var identity: String {
        codex?.email ?? claude?.email ?? codex?.accountHint ?? claude?.accountHint ?? ""
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
            // The name is centred on its own; the plan and the rename button hang off its right.
            StepTitle(text: name)
                .lineLimit(1)
                .overlay(alignment: .trailing) {
                    nameAccessories
                        .fixedSize()
                        .alignmentGuide(.trailing) { $0[.leading] - (SW.Space.xs + 2) }
                }
                .frame(maxWidth: 230)
        }
    }

    @ViewBuilder
    private var nameAccessories: some View {
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

    /// Before the fill each bar starts empty, in whichever convention the user reads. The
    /// figures show their real values throughout, so a new account never reads as used up.
    private func meterStart(_ window: WindowDisplay) -> Double? {
        guard !hasFilled, window.remaining != nil else { return nil }
        return interface.preferences.quota == .remaining ? 0 : 100
    }

    @ViewBuilder
    private var limits: some View {
        VStack(spacing: 0) {
            VStack(spacing: SW.Space.sm) {
                if let quota, !quota.windows.isEmpty {
                    ForEach(quota.windows) { window in
                        WindowRow(
                            window: window,
                            meterRemaining: meterStart(window),
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
                        Text("Auto-redeem")
                            .font(.system(size: 12, weight: .medium))
                        Text(["At 3% left", savedResets(quota?.inventory)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(SW.Palette.textTertiary)
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
        case 0: "no saved resets"
        case 1: "1 saved reset"
        default: "\(count) saved resets"
        }
    }
}

// MARK: - Service tile

/// A neutral tile with the service's symbol. Progress circles it; results ride on a badge.
struct ServiceTile: View {
    enum State: Equatable { case plain, waiting, problem, connected }
    static let defaultSize: CGFloat = 52

    let provider: ProviderKind
    var size: CGFloat = ServiceTile.defaultSize
    var state: State = .plain
    var isStaticRender = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var badgeShown = false

    init(provider: ProviderKind, size: CGFloat = ServiceTile.defaultSize, state: State = .plain, isStaticRender: Bool = false) {
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
                    SignInTrace(size: size, cornerRadius: size * 0.27, isStatic: isStaticRender)
                        .transition(.opacity)
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
            .onAppear { popBadgeIfConnected() }
            .onChange(of: state) { _, _ in popBadgeIfConnected() }
            .accessibilityHidden(true)
    }

    /// The success badge springs in each time the tile arrives at connected.
    private func popBadgeIfConnected() {
        guard state == .connected else {
            badgeShown = false
            return
        }
        guard !isStaticRender, !reduceMotion, !badgeShown else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.62).delay(0.12)) { badgeShown = true }
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

/// A short accent stroke travelling round the tile's border while the browser has the user.
private struct SignInTrace: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let isStatic: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelled: CGFloat = 0

    private var perimeter: CGFloat { 4 * (size - 2 * cornerRadius) + 2 * .pi * cornerRadius }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let segment = perimeter * 0.22
        // Drawn on the tile's own border, so there is no second frame around it.
        shape
            .inset(by: 0.75)
            .stroke(
                SW.Palette.accent,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [segment, perimeter - segment], dashPhase: travelled)
            )
            .frame(width: size, height: size)
        .onAppear {
            guard !isStatic, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { travelled = -perimeter }
        }
        .accessibilityHidden(true)
    }
}

/// Adding an account once one exists: a native menu straight to the email step for the chosen
/// service. The full service list is only for the first account.
struct AddAccountMenu: View {
    @ObservedObject var model: GuardAppModel
    let title: String
    var showsIcon = false
    let isStaticRender: Bool

    var body: some View {
        if isStaticRender {
            label
                .font(.system(size: showsIcon ? 12 : 12.5, weight: .medium))
                .foregroundStyle(showsIcon ? SW.Palette.textSecondary : SW.Palette.textPrimary)
                .padding(.horizontal, SW.Space.sm)
                .frame(height: 24)
        } else {
            Menu {
                ForEach(ProviderKind.allCases) { provider in
                    Button(provider.title) { model.startEnrollment(provider) }
                        .disabled(!model.canAdd(provider))
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(showsIcon ? SW.Palette.textSecondary : SW.Palette.textPrimary)
            .disabled(model.isReadOnly)
            .accessibilityLabel(title)
        }
    }

    @ViewBuilder
    private var label: some View {
        if showsIcon {
            Label(title, systemImage: "plus")
        } else {
            Text(title)
        }
    }
}
