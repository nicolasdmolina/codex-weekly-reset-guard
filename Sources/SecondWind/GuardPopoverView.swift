import SwiftUI

struct GuardPopoverView: View {
    @ObservedObject var model: GuardAppModel
    @ObservedObject var interface: GuardInterfaceModel
    var canvasHeight: CGFloat = SW.Size.popoverHeight
    var isStaticRender = false
    @State private var isOnScreen = false

    var body: some View {
        if let reference = model.referenceDate {
            shell(now: reference)
        } else {
            // Reading ages and passed reset times move with the clock, not only with snapshots.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                shell(now: context.date)
            }
        }
    }

    private func shell(now: Date) -> some View {
        let summary = PopoverSummary.make(model: model, interface: interface, now: now)
        let enrollment = interface.page == .accounts ? model.enrollmentPhase : nil
        return VStack(spacing: 0) {
            if interface.page == .settings {
                settingsHeader
            } else if let enrollment, enrollment != .choose || model.hasAccounts {
                enrollmentHeader(enrollment)
            } else {
                header(summary)
            }
            Rectangle().fill(SW.Palette.hairline).frame(height: 1)
            scrollingContent(now: now)
            Rectangle().fill(SW.Palette.hairline).frame(height: 1)
            footer(now: now)
        }
        .frame(width: SW.Size.popoverWidth, height: canvasHeight)
        .background(SW.Palette.canvas)
        .foregroundStyle(SW.Palette.textPrimary)
        .tint(SW.Palette.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Second Wind")
    }

    // MARK: Header

    private func header(_ summary: PopoverSummary) -> some View {
        HStack(spacing: SW.Space.md) {
            BrandMark()
            VStack(alignment: .leading, spacing: SW.Space.xxs) {
                Text("Second Wind")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: SW.Space.xs) {
                    if let symbol = summarySymbol(summary) {
                        Image(systemName: symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(summary.tone == .neutral ? SW.Palette.textSecondary : summary.tone.color)
                    }
                    Text(summary.text)
                        .font(.system(size: 12))
                        .foregroundStyle(summary.tone == .neutral ? SW.Palette.textSecondary : summary.tone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(height: 16)
            }
            Spacer(minLength: SW.Space.sm)
            if model.isPreview || model.isReadOnly {
                Text(model.isPreview ? "Preview" : "Read-only")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SW.Palette.textSecondary)
                    .padding(.horizontal, SW.Space.sm)
                    .padding(.vertical, SW.Space.xxs + 1)
                    .background(SW.Palette.surfaceRaised, in: Capsule())
            }
            if model.hasAccounts {
                RefreshButton(isChecking: model.isBusyChecking) { model.checkNow() }
                    .disabled(model.isBusyChecking)
            }
        }
        .padding(.horizontal, SW.Space.lg)
        .padding(.vertical, SW.Space.md)
        .accessibilityElement(children: .contain)
    }

    /// Colour never carries a status alone: each summary tone has its own symbol.
    private func summarySymbol(_ summary: PopoverSummary) -> String? {
        if let symbol = summary.symbol { return symbol }
        switch summary.tone {
        case .good: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.circle.fill"
        case .neutral: return model.hasAccounts ? "clock" : nil
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: SW.Space.sm) {
            Button {
                interface.showAccounts()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SWIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Back to accounts")
            .accessibilityLabel("Back to accounts")
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: SW.Space.sm)
            if model.isPreview {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SW.Palette.textSecondary)
                    .padding(.horizontal, SW.Space.sm)
                    .padding(.vertical, SW.Space.xxs + 1)
                    .background(SW.Palette.surfaceRaised, in: Capsule())
            }
        }
        .padding(.leading, SW.Space.md)
        .padding(.trailing, SW.Space.lg)
        .padding(.vertical, SW.Space.md)
        .frame(height: 54)
    }

    /// The title never moves: the back button keeps its slot even on the step that has none.
    private func enrollmentHeader(_ phase: EnrollmentPhase) -> some View {
        let canGoBack: Bool = switch phase {
        case .choose, .email: !model.isAddingProfile
        case let .waiting(_, checking): !checking
        case .problem, .connected: true
        }
        let backLabel: String = switch phase {
        case .waiting, .problem: "Cancel sign-in"
        case .connected: "Back to accounts"
        default: "Back"
        }
        return HStack(spacing: SW.Space.sm) {
            Button {
                // From the result, back is the same as Done: the list, with the new account lit.
                if case .connected = phase, let ref = model.finishEnrollment() {
                    interface.reveal(ref)
                } else {
                    model.enrollmentBack()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SWIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help(backLabel)
            .accessibilityLabel(backLabel)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityHidden(!canGoBack)
            Text("Add account")
                .font(.system(size: 13.5, weight: .semibold))
            Spacer(minLength: SW.Space.sm)
            if model.isPreview {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SW.Palette.textSecondary)
                    .padding(.horizontal, SW.Space.sm)
                    .padding(.vertical, SW.Space.xxs + 1)
                    .background(SW.Palette.surfaceRaised, in: Capsule())
            }
        }
        .padding(.leading, SW.Space.md)
        .padding(.trailing, SW.Space.lg)
        .padding(.vertical, SW.Space.md)
        // Same height as the app header it replaces, so the divider never jumps.
        .frame(height: 61)
    }

    // MARK: Content

    @ViewBuilder
    private func scrollingContent(now: Date) -> some View {
        if interface.page == .accounts, let phase = model.enrollmentPhase {
            VStack(spacing: 0) {
                // Before a sign-in starts the list's notices still apply, such as a provider that
                // failed to load and so has a greyed-out row.
                if phase.account == nil { enrollmentNotices }
                EnrollmentFlowView(model: model, interface: interface, phase: phase, isStaticRender: isStaticRender, now: now)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isStaticRender {
            pageContent(now: now)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    pageContent(now: now)
                }
                .scrollIndicators(.automatic)
                .onChange(of: interface.scrollTarget) { _, target in
                    // A closed popover keeps the request until it appears and can lay out.
                    if isOnScreen { scroll(to: target, with: proxy, animated: true) }
                }
                .onAppear {
                    isOnScreen = true
                    scroll(to: interface.scrollTarget, with: proxy, animated: false)
                }
                .onDisappear { isOnScreen = false }
            }
        }
    }

    /// A just-opened popover can finish layout a frame or two after it appears, and a scroll
    /// before that lands nowhere. The request repeats briefly and is cleared only afterwards.
    private func scroll(to target: AccountRef?, with proxy: ScrollViewProxy, animated: Bool) {
        guard let target else { return }
        Task { @MainActor in
            for delay in [0.0, 0.12, 0.3] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard interface.scrollTarget == target else { return }
                withAnimation(animated && delay == 0 ? SW.Motion.easeOut(SW.Motion.standard, reduceMotion: false) : nil) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            if interface.scrollTarget == target { interface.scrollTarget = nil }
        }
    }

    @ViewBuilder
    private func pageContent(now: Date) -> some View {
        switch interface.page {
        case .settings:
            SettingsPanel(interface: interface, isStaticRender: isStaticRender)
                .padding(SW.Space.lg)
        case .accounts:
            accountsContent(now: now)
        }
    }

    @ViewBuilder
    private var enrollmentNotices: some View {
        let notices = interface.notices
        if model.isReadOnly || !notices.isEmpty || model.banner != nil {
            VStack(spacing: SW.Space.sm) {
                if model.isReadOnly {
                    NoticeRow(symbol: "eye", text: "Diagnostics mode. Resets, sign-in and launch at login are off.", tone: .neutral)
                }
                ForEach(notices) { notice in
                    NoticeRow(symbol: notice.symbol, text: notice.text, tone: notice.tone) {
                        interface.dismissNotice(notice.id)
                    }
                }
                if let banner = model.banner {
                    NoticeRow(symbol: "info.circle", text: banner, tone: .neutral)
                }
            }
            .padding([.horizontal, .top], SW.Space.lg)
        }
    }

    private func accountsContent(now: Date) -> some View {
        VStack(alignment: .leading, spacing: SW.Space.lg) {
            if model.isReadOnly {
                NoticeRow(
                    symbol: "eye",
                    text: "Diagnostics mode. Resets, sign-in and launch at login are off.",
                    tone: .neutral
                )
            }
            ForEach(interface.notices) { notice in
                NoticeRow(symbol: notice.symbol, text: notice.text, tone: notice.tone) {
                    interface.dismissNotice(notice.id)
                }
            }
            if let pending = interface.pendingReveal {
                NoticeRow(
                    symbol: "hourglass",
                    text: "Opening that \(pending.provider.title) account once its accounts load.",
                    tone: .neutral
                ) {
                    interface.cancelPendingReveal()
                }
            }
            if let transient = interface.transientNotice {
                NoticeRow(symbol: "checkmark.circle", text: transient, tone: .good)
            }
            if let banner = model.banner {
                NoticeRow(symbol: "info.circle", text: banner, tone: .neutral)
            }

            if !model.profiles.isEmpty {
                AccountSection(title: "Codex", detail: model.profiles.contains(where: \.autoResetEnabled) ? "Auto-redeem at 3%" : "Auto-redeem off") {
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { RowDivider() }
                        CodexAccountRow(
                            profile: profile,
                            quota: QuotaDisplayBuilder.codex(profile, now: now),
                            interface: interface,
                            isStaticRender: isStaticRender,
                            isReadOnly: model.isReadOnly,
                            now: now,
                            onToggle: { model.setAutoReset(profileID: profile.id, enabled: $0) },
                            onReconnect: { model.reconnect(profileID: profile.id) }
                        )
                    }
                }
            }

            if !model.claudeProfiles.isEmpty {
                AccountSection(title: "Claude", detail: "Alert at 10%") {
                    ForEach(Array(model.claudeProfiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { RowDivider() }
                        ClaudeAccountRow(
                            profile: profile,
                            quota: QuotaDisplayBuilder.claude(profile, now: now),
                            interface: interface,
                            isStaticRender: isStaticRender,
                            isReadOnly: model.isReadOnly,
                            now: now,
                            onConnect: { model.connectClaude(profileID: profile.id) },
                            onCancel: { model.cancelClaudeSignIn(profileID: profile.id) },
                            onOpenUsage: { model.openClaudeUsage() }
                        )
                    }
                }
            }

            if !model.history.isEmpty {
                ActivityList(events: Array(model.history.prefix(3)), referenceDate: model.referenceDate)
            }
        }
        .padding(SW.Space.lg)
    }

    // MARK: Footer

    private func footer(now: Date) -> some View {
        HStack(spacing: SW.Space.sm) {
            if interface.page == .accounts && model.enrollmentPhase == nil && !model.isReadOnly {
                AddAccountMenu(model: model, title: "Add account", showsIcon: true, isStaticRender: isStaticRender)
            }
            Spacer()
            if let checked = model.lastCheckedAt, model.enrollmentPhase == nil || interface.page != .accounts {
                Text("Checked \(relativeDescription(checked, reference: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .monospacedDigit()
            }
            footerMenu
        }
        .padding(.horizontal, SW.Space.md)
        .padding(.vertical, SW.Space.sm)
        .frame(height: 40)
    }

    @ViewBuilder
    private var footerMenu: some View {
        if model.isReadOnly {
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(SWQuietButtonStyle())
        } else if isStaticRender {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(SW.Palette.textSecondary)
                .frame(width: 28, height: 24)
                .accessibilityLabel("More options")
        } else {
            Menu {
                if interface.page == .accounts {
                    Button("Settings…") { interface.showSettings() }
                        .keyboardShortcut(",")
                } else {
                    Button("Accounts") { interface.showAccounts() }
                }
                if !model.claudeProfiles.isEmpty {
                    Button("Open Claude usage settings") { model.openClaudeUsage() }
                }
                Divider()
                Button("Quit Second Wind") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // A borderless menu draws in the tint colour; the footer stays quiet beside the
            // primary button above it.
            .tint(SW.Palette.textSecondary)
            .accessibilityLabel("More options")
        }
    }
}

// MARK: - Brand

private struct BrandMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous)
            .fill(SW.Palette.accent.opacity(0.16))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: "wind")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SW.Palette.accent)
            }
            .accessibilityHidden(true)
    }
}

private struct RefreshButton: View {
    let isChecking: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SWIconButtonStyle())
        .help("Check now")
        .accessibilityLabel(isChecking ? "Checking" : "Check now")
        .onChange(of: isChecking) { _, checking in
            guard !reduceMotion else { return }
            if checking {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            } else {
                withAnimation(.default) { spin = false }
            }
        }
    }
}

// MARK: - Sections

struct AccountSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SW.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, SW.Space.xs)
            VStack(spacing: 0) { content }
                .background(SW.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous)
                        .strokeBorder(SW.Palette.hairline)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) accounts")
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(SW.Palette.hairline).frame(height: 1).padding(.leading, SW.Space.md)
    }
}

// MARK: - Account rows

/// One account: heading with its menu, the provider-specific body, the status line and the
/// row's own persistent feedback. Rename and removal happen inline, never in a modal.
private struct AccountRow<Details: View, Actions: View>: View {
    let ref: AccountRef?
    let provider: ProviderKind
    let name: String
    let hint: String
    let badge: String?
    let quota: AccountQuotaDisplay
    let status: StatusPresentation
    @ObservedObject var interface: GuardInterfaceModel
    let isStaticRender: Bool
    let isReadOnly: Bool
    let now: Date
    @ViewBuilder var details: Details
    @ViewBuilder var actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var editor: GuardInterfaceModel.AccountEditor? {
        guard let ref, interface.editor?.account == ref else { return nil }
        return interface.editor
    }

    private var isBusy: Bool { ref.map { interface.busyAccounts.contains($0) } ?? false }
    private var isHighlighted: Bool { ref != nil && interface.highlighted == ref }

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm + 2) {
            heading
            if case .renaming = editor { feedback }
            if case .confirmingRemoval = editor {
                RemovalConfirmation(
                    name: name,
                    provider: provider,
                    keepsResetRecord: ref.map { interface.removalKeepsResetRecord(for: $0) } ?? false,
                    isBusy: isBusy,
                    onCancel: { interface.cancelEditing() },
                    onRemove: { if let ref { interface.remove(ref, displayName: name) } }
                )
            } else {
                if !quota.windows.isEmpty {
                    VStack(spacing: SW.Space.sm - 1) {
                        ForEach(quota.windows) { window in
                            WindowRow(
                                window: window,
                                convention: interface.preferences.quota,
                                resetStyle: interface.preferences.resetTimes,
                                now: now,
                                isStatic: isStaticRender,
                                onToggleStyle: { interface.toggleResetTimeStyle() }
                            )
                        }
                    }
                }
                details
                HStack(alignment: .center, spacing: SW.Space.sm) {
                    StatusLine(symbol: status.symbol, text: status.text, tone: status.tone, age: status.age)
                    Spacer(minLength: SW.Space.xs)
                    actions
                }
            }
            if !isRenaming { feedback }
        }
        .padding(SW.Space.md)
        .background(SW.Palette.accent.opacity(isHighlighted ? 0.10 : 0))
        .animation(SW.Motion.easeOut(SW.Motion.slow, reduceMotion: reduceMotion || isStaticRender), value: isHighlighted)
        .contextMenu { if !isStaticRender { menuItems } }
        .id(ref)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(provider.title), \(status.title)")
    }

    private var isRenaming: Bool {
        if case .renaming = editor { return true }
        return false
    }

    /// A failed action's result sits beside the control it belongs to: under the rename field
    /// while renaming, otherwise at the foot of the row.
    @ViewBuilder
    private var feedback: some View {
        if let ref, let feedback = interface.accountFeedback[ref] {
            FeedbackLine(feedback: feedback) { interface.dismissFeedback(for: ref) }
        }
    }

    // MARK: Heading

    @ViewBuilder
    private var heading: some View {
        if case .renaming = editor {
            renameHeading
        } else {
            HStack(alignment: .top, spacing: SW.Space.sm) {
                VStack(alignment: .leading, spacing: SW.Space.xxs) {
                    HStack(spacing: SW.Space.xs + 2) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SW.Palette.textSecondary)
                                .padding(.horizontal, SW.Space.xs + 1)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(SW.Palette.hairline))
                        }
                        accountMenu
                    }
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(SW.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: SW.Space.sm)
                if let headline = quota.headline, let remaining = headline.remaining {
                    HeadlineFigure(
                        remaining: remaining,
                        label: headline.label,
                        convention: interface.preferences.quota,
                        tone: headline.isWarning ? .caution : .neutral,
                        isCurrent: headline.state == .current
                    )
                }
            }
        }
    }

    private var renameHeading: some View {
        VStack(alignment: .leading, spacing: SW.Space.xs + 2) {
            HStack(spacing: SW.Space.sm) {
                if isStaticRender {
                    Text(interface.draftName)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SW.Space.sm)
                        .frame(height: 24)
                        .background(SW.Palette.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SW.Palette.accent.opacity(0.7), lineWidth: 1.5))
                } else {
                    RenameField(interface: interface, provider: provider) {
                        interface.commitRename(currentName: name)
                    }
                }
                Button("Cancel") { interface.cancelEditing() }
                    .buttonStyle(SWQuietButtonStyle())
                    .disabled(isBusy)
                Button(isBusy ? "Saving…" : "Save") { interface.commitRename(currentName: name) }
                    .buttonStyle(SWPrimaryButtonStyle())
                    .disabled(isBusy)
            }
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(SW.Palette.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var accountMenu: some View {
        if ref != nil && !isReadOnly {
            if isStaticRender {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .frame(width: 20, height: 16)
            } else {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // A borderless menu draws in the tint colour; the row menu stays quiet.
                .tint(SW.Palette.textTertiary)
                .help("Account options")
                .accessibilityLabel("Options for \(name)")
                .disabled(isBusy)
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let ref, !isReadOnly {
            Button("Rename…") { interface.beginRename(ref, currentName: name) }
            if interface.preflightCommand(for: ref) != nil || interface.isPreview {
                Button("Copy pre-job check") { interface.copyPreflightCommand(for: ref) }
            }
            Divider()
            Button("Remove…", role: .destructive) { interface.confirmRemoval(ref) }
        }
    }
}

/// The text a row's status line shows, with its colour and symbol.
struct StatusPresentation {
    let symbol: String
    let title: String
    let text: String
    let tone: SWTone
    /// How old the reading is, drawn quieter than the message so it never dangles on its own line.
    var age: String? = nil
}

private struct CodexAccountRow: View {
    let profile: GuardProfilePresentation
    let quota: AccountQuotaDisplay
    @ObservedObject var interface: GuardInterfaceModel
    let isStaticRender: Bool
    let isReadOnly: Bool
    let now: Date
    let onToggle: (Bool) -> Void
    let onReconnect: () -> Void

    var body: some View {
        AccountRow(
            ref: AccountRef(provider: .codex, rawID: profile.id),
            provider: .codex,
            name: profile.displayName,
            hint: profile.accountHint,
            badge: profile.planName,
            quota: quota,
            status: status,
            interface: interface,
            isStaticRender: isStaticRender,
            isReadOnly: isReadOnly,
            now: now
        ) {
            if let inventory = quota.inventory {
                InventoryLine(
                    inventory: inventory,
                    now: now,
                    isExpanded: ref.map { interface.expandedInventories.contains($0) } ?? false,
                    isStatic: isStaticRender,
                    onToggle: { if let ref { interface.toggleInventoryDetail(ref) } }
                )
            }
            if profile.isConnected || profile.autoResetEnabled {
                autoRedeem
            }
        } actions: {
            if !profile.isConnected && !isReadOnly {
                Button("Connect", action: onReconnect)
                    .buttonStyle(SWPrimaryButtonStyle())
            }
        }
    }

    private var ref: AccountRef? { AccountRef(provider: .codex, rawID: profile.id) }

    /// A labelled row like the windows above it, so the switch never floats on its own.
    private var autoRedeem: some View {
        HStack(spacing: SW.Space.sm) {
            Text("Auto-redeem")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SW.Palette.textSecondary)
            Spacer(minLength: SW.Space.sm)
            if isStaticRender {
                StaticToggle(isOn: profile.autoResetEnabled, label: "Auto-redeem")
            } else {
                Toggle("Auto-redeem", isOn: Binding(get: { profile.autoResetEnabled }, set: { onToggle($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(isReadOnly || (!profile.isConnected && !profile.autoResetEnabled))
                    .help("Redeem a saved reset after two weekly readings at or below 3% left")
            }
        }
    }

    private var status: StatusPresentation {
        let tone: SWTone = switch profile.status {
        case .healthy, .redeeming: .neutral
        case .verified: .good
        case .nearLimit, .confirming: .caution
        case .attention, .disconnected: .critical
        }
        let base: String
        if profile.detail.isEmpty {
            base = profile.status.title
        } else if !profile.isConnected || profile.status == .nearLimit {
            // A warning's detail names the window and what to do; the title would repeat it.
            base = profile.detail
        } else {
            base = "\(profile.status.title). \(profile.detail)"
        }
        if profile.status == .healthy, quota.inventoryUnconfirmed, !quota.isBlocked, quota.usageAccess != .unknown,
           case let .current(date) = quota.age {
            let age = QuotaTimeFormat.age(of: date, reference: now)
            return StatusPresentation(
                symbol: "questionmark.circle",
                title: "Saved resets not confirmed",
                text: profile.autoResetEnabled
                    ? "Auto-redeem waits until Codex reports saved resets."
                    : "Saved resets did not load.",
                tone: .neutral,
                age: "updated \(age)"
            )
        }
        return StatusComposer.compose(
            symbol: profile.status.symbolName,
            title: profile.status.title,
            base: base,
            isRoutine: profile.status == .healthy,
            tone: tone,
            quota: quota,
            providerName: "Codex",
            now: now
        )
    }
}

private struct ClaudeAccountRow: View {
    let profile: ClaudeProfilePresentation
    let quota: AccountQuotaDisplay
    @ObservedObject var interface: GuardInterfaceModel
    let isStaticRender: Bool
    let isReadOnly: Bool
    let now: Date
    let onConnect: () -> Void
    let onCancel: () -> Void
    let onOpenUsage: () -> Void

    var body: some View {
        AccountRow(
            ref: AccountRef(provider: .claude, rawID: profile.id),
            provider: .claude,
            name: profile.displayName,
            hint: profile.accountHint,
            badge: profile.planName,
            quota: quota,
            status: status,
            interface: interface,
            isStaticRender: isStaticRender,
            isReadOnly: isReadOnly,
            now: now
        ) {
            EmptyView()
        } actions: {
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !isReadOnly {
            switch profile.status {
            case .signedOut, .attention:
                if profile.status == .attention && !profile.windows.isEmpty {
                    Button("Reconnect", action: onConnect).buttonStyle(SWSecondaryButtonStyle())
                } else {
                    Button("Sign in", action: onConnect).buttonStyle(SWPrimaryButtonStyle())
                }
            case .signingIn:
                HStack(spacing: SW.Space.xs) {
                    if let url = profile.signInURL {
                        Button("Open page") { NSWorkspace.shared.open(url) }
                            .buttonStyle(SWSecondaryButtonStyle())
                    }
                    Button("Cancel", action: onCancel).buttonStyle(SWQuietButtonStyle())
                }
            case .low:
                Button(action: onOpenUsage) {
                    Label("Use a reset", systemImage: "arrow.up.forward")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(SWPrimaryButtonStyle())
                .help("Opens Claude Settings › Usage, where you can reset a limit for free if one is available")
            case .healthy, .checking:
                EmptyView()
            }
        }
    }

    private var status: StatusPresentation {
        let tone: SWTone = switch profile.status {
        case .healthy, .checking, .signingIn: .neutral
        case .low: .caution
        case .signedOut, .attention: .critical
        }
        let base = profile.status == .healthy
            ? profile.status.title
            : (profile.detail.isEmpty ? profile.status.title : profile.detail)
        return StatusComposer.compose(
            symbol: profile.status.symbolName,
            title: profile.status.title,
            base: base,
            isRoutine: profile.status == .healthy,
            tone: tone,
            quota: quota,
            providerName: "Claude",
            now: now
        )
    }
}

/// Adds the reading's age and refill state to a row's status. Freshness is per account: a
/// figure that did not update says how old it is right beside it.
enum StatusComposer {
    static func compose(
        symbol: String,
        title: String,
        base: String,
        isRoutine: Bool,
        tone: SWTone,
        quota: AccountQuotaDisplay,
        providerName: String,
        now: Date
    ) -> StatusPresentation {
        let updated = quota.age.lastSuccess.map { "updated \(QuotaTimeFormat.age(of: $0, reference: now))" }
        if tone != .critical, quota.isBlocked {
            return StatusPresentation(
                symbol: "hand.raised.fill",
                title: "Usage blocked",
                text: "\(providerName) says usage is blocked.",
                tone: .caution,
                age: updated
            )
        }
        if tone != .critical, quota.awaitingRefill {
            return StatusPresentation(
                symbol: "clock.arrow.circlepath",
                title: "Waiting for refill",
                text: "Reset time passed. Waiting for \(providerName) to confirm the refill.",
                tone: .neutral
            )
        }
        switch quota.age {
        case let .current(date):
            let age = QuotaTimeFormat.age(of: date, reference: now)
            if tone != .critical, quota.usageAccess == .unknown {
                return StatusPresentation(
                    symbol: "questionmark.circle",
                    title: "Usage not confirmed",
                    text: "\(providerName) did not say whether usage is allowed.",
                    tone: .neutral,
                    age: "updated \(age)"
                )
            }
            return StatusPresentation(
                symbol: symbol,
                title: title,
                text: isRoutine ? "\(title) · updated \(age)" : sentence(base),
                tone: tone,
                age: isRoutine ? nil : "updated \(age)"
            )
        case let .stale(date):
            guard tone != .critical else { break }
            if quota.isRestored {
                return StatusPresentation(
                    symbol: "clock.badge.exclamationmark",
                    title: "Not up to date",
                    text: "Showing the reading from \(QuotaTimeFormat.age(of: date, reference: now)), before Second Wind restarted. Checking again.",
                    tone: .neutral
                )
            }
            return StatusPresentation(
                symbol: "clock.badge.exclamationmark",
                title: "Not up to date",
                text: "No new reading for \(QuotaTimeFormat.age(of: date, reference: now).replacingOccurrences(of: " ago", with: "")). Figures may be out of date.",
                tone: .neutral
            )
        case let .failed(lastSuccess):
            if let lastSuccess {
                return StatusPresentation(
                    symbol: symbol,
                    title: title,
                    text: sentence(base),
                    tone: tone,
                    age: "last good reading \(QuotaTimeFormat.age(of: lastSuccess, reference: now))"
                )
            }
        case .never:
            break
        }
        return StatusPresentation(symbol: symbol, title: title, text: base, tone: tone)
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}

// MARK: - Quota pieces

private struct HeadlineFigure: View {
    let remaining: Double
    let label: String
    let convention: QuotaConvention
    let tone: SWTone
    let isCurrent: Bool

    var body: some View {
        let percent = convention.percent(remaining: remaining)
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(percent)%")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(figureColor)
                .contentTransition(.numericText(value: Double(percent)))
            Text("\(convention.word) · \(label.lowercased())")
                .font(.system(size: 10.5))
                .foregroundStyle(SW.Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(percent) percent \(convention.word), \(label) limit\(isCurrent ? "" : ", not up to date")")
    }

    private var figureColor: Color {
        if !isCurrent { return SW.Palette.textTertiary }
        return tone == .caution || tone == .critical ? tone.color : SW.Palette.textPrimary
    }
}

/// One limit window: label, meter, figure and renewal time. A window the provider did not
/// report says so in words and never draws an empty meter, which would read as zero.
struct WindowRow: View {
    let window: WindowDisplay
    let convention: QuotaConvention
    let resetStyle: ResetTimeStyle
    let now: Date
    let isStatic: Bool
    let onToggleStyle: () -> Void

    var body: some View {
        HStack(spacing: SW.Space.sm) {
            Text(window.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SW.Palette.textSecondary)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            if let remaining = window.remaining {
                HeadroomMeter(
                    remaining: remaining,
                    threshold: window.alertLine,
                    convention: convention,
                    tone: window.isWarning ? .caution : .neutral,
                    isCurrent: window.state == .current,
                    animate: !isStatic
                )
                Text("\(convention.percent(remaining: remaining))%")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: remaining))
                    .foregroundStyle(window.state == .current ? (window.isWarning ? SW.Palette.caution : SW.Palette.textPrimary) : SW.Palette.textTertiary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("Not reported")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            resetLabel
                .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) limit")
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: resetStyle == .relative ? "Show clock times" : "Show countdowns", onToggleStyle)
    }

    private var resetText: String? {
        guard let reset = window.resetsAt else { return nil }
        return QuotaTimeFormat.resetText(reset, reference: now, style: resetStyle)
    }

    @ViewBuilder
    private var resetLabel: some View {
        if window.state == .awaitingRefill {
            HStack(spacing: SW.Space.xs - 1) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                Text("Refill due")
            }
            .font(.system(size: 11))
            .foregroundStyle(SW.Palette.textSecondary)
            .lineLimit(1)
        } else if let resetText {
            let label = HStack(spacing: SW.Space.xs - 1) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(resetText)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(SW.Palette.textTertiary)
            .monospacedDigit()
            if isStatic {
                label
            } else {
                Button(action: onToggleStyle) { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(helpText)
            }
        }
    }

    private var helpText: String {
        guard let reset = window.resetsAt else { return "" }
        let other = QuotaTimeFormat.resetText(reset, reference: now, style: resetStyle.toggled) ?? ""
        return "Renews \(other). Click to show \(resetStyle == .relative ? "clock times" : "countdowns")."
    }

    private var accessibilityValue: String {
        guard let remaining = window.remaining else { return "not reported" }
        var value = "\(convention.percent(remaining: remaining)) percent \(convention.word)"
        if window.state == .awaitingRefill {
            value += ", reset time passed, waiting for the refill"
        } else if let resetText {
            value += ", renews \(resetText)"
        }
        if window.state == .stale { value += ", not up to date" }
        return value
    }
}

/// Saved Codex resets with their own expiry, kept apart from the window's renewal time. An
/// unknown count is said in words and is never drawn as zero. With several resets
/// the line opens a list of every expiry Codex supplied, and says how many came without one.
private struct InventoryLine: View {
    let inventory: InventoryDisplay
    let now: Date
    let isExpanded: Bool
    let isStatic: Bool
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.xs + 1) {
            if inventory.hasDetail && !isStatic {
                Button(action: onToggle) { summary.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide expiry dates" : "Show every expiry date")
                    .accessibilityLabel(text)
                    .accessibilityHint(isExpanded ? "Hides the expiry dates" : "Shows every expiry date")
            } else {
                summary
            }
            if isExpanded && inventory.hasDetail {
                detail
                    .transition(.opacity)
            }
        }
        .animation(SW.Motion.easeOut(SW.Motion.quick, reduceMotion: reduceMotion || isStatic), value: isExpanded)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: SW.Space.xs + 1) {
            Image(systemName: symbol)
                .foregroundStyle(SW.Palette.textTertiary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            if inventory.hasDetail {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .baselineOffset(0.5)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(SW.Palette.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: SW.Space.xxs + 1) {
            if case let .known(_, listed, _, _, _) = inventory {
                ForEach(Array(listed.enumerated()), id: \.offset) { _, expiry in
                    switch expiry {
                    case let .on(date): Text("Expires \(QuotaTimeFormat.fullDate(date))")
                    case .doesNotExpire: Text("Does not expire")
                    }
                }
            }
            let unlisted = inventory.unlistedCount
            if unlisted > 0 {
                Text(unlisted == 1 ? "1 more without a listed date" : "\(unlisted) more without listed dates")
                    .foregroundStyle(SW.Palette.textTertiary)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(SW.Palette.textSecondary)
        .padding(.leading, 18)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch inventory {
        case .unknown: "questionmark.circle"
        case .known: "arrow.counterclockwise.circle"
        }
    }

    private var text: String {
        switch inventory {
        case let .unknown(lastCount, checkedAt):
            guard let lastCount, let checkedAt else { return "Saved resets unknown" }
            return "Saved resets not reported · \(lastCount) when checked \(QuotaTimeFormat.age(of: checkedAt, reference: now))"
        case let .known(count, listed, datesReported, checkedAt, isCurrent):
            var parts: [String] = []
            if count == 0 {
                parts.append("No saved resets")
            } else {
                parts.append(count == 1 ? "1 saved reset" : "\(count) saved resets")
                parts.append(expiryPhrase(count: count, listed: listed, datesReported: datesReported))
            }
            if !isCurrent { parts.append("checked \(QuotaTimeFormat.age(of: checkedAt, reference: now))") }
            return parts.joined(separator: " · ")
        }
    }

    /// "next expires" only when every reset is listed; otherwise "one expires", which stays true
    /// whatever the unlisted resets hold.
    private func expiryPhrase(count: Int, listed: [InventoryDisplay.Expiry], datesReported: Bool) -> String {
        guard datesReported else { return "expiry not reported" }
        let complete = inventory.unlistedCount == 0
        guard let first = listed.first else { return count == 1 ? "expiry not listed" : "expiries not listed" }
        switch first {
        case let .on(date):
            let when = QuotaTimeFormat.expiry(date, reference: now)
            if count == 1 { return "expires \(when)" }
            return complete ? "next expires \(when)" : "one expires \(when)"
        case .doesNotExpire:
            if count == 1 { return "does not expire" }
            return complete ? "none expire" : "\(listed.count) listed do not expire"
        }
    }
}

/// The signature element: a capsule with a tick at the alert line. It fills with what the
/// chosen convention counts, headroom or use, so the figure and the fill always agree. When a
/// reset lands, the fill sweeps on the slow motion token.
private struct HeadroomMeter: View {
    let remaining: Double
    let threshold: Double
    let convention: QuotaConvention
    let tone: SWTone
    let isCurrent: Bool
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = max(0, min(100, remaining))
            let fraction = (convention == .remaining ? clamped : 100 - clamped) / 100
            let tick = (convention == .remaining ? threshold : 100 - threshold) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(SW.Palette.track)
                    .frame(height: SW.Size.meterHeight)
                Capsule()
                    .fill(fillColor)
                    .frame(width: width * fraction, height: SW.Size.meterHeight)
                // One 1 pt mark at track height: cut through the fill where the fill covers it, so
                // it reads the same on any row tint, and drawn on the empty track where it does not.
                let covered = width * tick < width * fraction - 1
                Rectangle()
                    .fill(covered ? Color.black : SW.Palette.textTertiary)
                    .frame(width: 1, height: SW.Size.meterHeight)
                    .offset(x: width * tick)
                    .blendMode(covered ? .destinationOut : .normal)
            }
            .compositingGroup()
            .frame(height: geometry.size.height)
        }
        .frame(height: SW.Size.meterHeight)
        .animation(animate ? SW.Motion.easeOut(SW.Motion.slow, reduceMotion: reduceMotion) : nil, value: remaining)
        .animation(animate ? SW.Motion.easeOut(SW.Motion.standard, reduceMotion: reduceMotion) : nil, value: convention)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        guard isCurrent else { return SW.Palette.textTertiary.opacity(0.55) }
        switch tone {
        case .caution: return SW.Palette.caution
        case .critical: return SW.Palette.critical
        case .neutral, .good: return SW.Palette.accent
        }
    }
}

// MARK: - Inline account editing

private struct RenameField: View {
    @ObservedObject var interface: GuardInterfaceModel
    let provider: ProviderKind
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Account name", text: $interface.draftName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onExitCommand { interface.cancelEditing() }
            .onChange(of: interface.draftName) { _, _ in interface.limitDraft(for: provider) }
            .onAppear { isFocused = true }
            .accessibilityLabel("Account name")
    }
}

private struct RemovalConfirmation: View {
    let name: String
    let provider: ProviderKind
    let keepsResetRecord: Bool
    let isBusy: Bool
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm) {
            Text("Remove \(name) from Second Wind?")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Second Wind deletes only its own copy of the sign-in. Your \(provider == .codex ? "Codex" : "Claude Code") sign-in elsewhere stays.")
                .font(.system(size: 11.5))
                .foregroundStyle(SW.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if keepsResetRecord {
                Text("A reset is still being confirmed, so its record stays and it is never sent twice.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SW.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SW.Space.sm) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SWQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button(isBusy ? "Removing…" : "Remove", action: onRemove)
                    .buttonStyle(SWDestructiveButtonStyle())
                    .disabled(isBusy)
            }
        }
        .padding(.top, SW.Space.xs)
        .accessibilityElement(children: .contain)
    }
}

private struct FeedbackLine: View {
    let feedback: GuardInterfaceModel.Feedback
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SW.Space.sm) {
            switch feedback {
            case let .failure(message):
                StatusLine(symbol: "exclamationmark.circle.fill", text: message, tone: .critical)
            case let .success(message):
                StatusLine(symbol: "checkmark.circle.fill", text: message, tone: .good)
            }
            Spacer(minLength: SW.Space.xs)
            DismissButton(action: onDismiss)
        }
    }
}

/// A compact two- or three-way choice drawn in SwiftUI, so static renders match the app.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: KeyPath<Value, String>
    let accessibilityLabel: String
    let isStatic: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: SW.Space.xxs) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(SW.Motion.easeOut(SW.Motion.quick, reduceMotion: reduceMotion || isStatic)) {
                        selection = option
                    }
                } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? SW.Palette.textPrimary : SW.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(SW.Palette.controlThumb)
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: selectionSpace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(SW.Space.xxs)
        .background(SW.Palette.controlTrack, in: RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Activity and notices

private struct ActivityList: View {
    let events: [GuardHistoryEvent]
    let referenceDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm) {
            Text("Recent activity")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, SW.Space.xs)
            VStack(alignment: .leading, spacing: SW.Space.sm) {
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: SW.Space.sm) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(SW.Palette.accent)
                        Text(event.summary)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer(minLength: SW.Space.xs)
                        Text("\(event.profileName) · \(event.occurredAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(SW.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, SW.Space.xs)
        }
    }
}

struct NoticeRow: View {
    let symbol: String
    let text: String
    let tone: SWTone
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SW.Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                DismissButton(action: onDismiss)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(SW.Palette.textSecondary)
        .padding(.horizontal, SW.Space.md)
        .padding(.vertical, SW.Space.sm + 2)
        .background(SW.Palette.surface, in: RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous).strokeBorder(SW.Palette.hairline))
    }
}

struct StatusLine: View {
    let symbol: String
    let text: String
    let tone: SWTone
    var age: String? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                if let age {
                    Text(age.prefix(1).uppercased() + age.dropFirst())
                        .font(.system(size: 11))
                        .foregroundStyle(SW.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tone == .neutral || tone == .good ? SW.Palette.textSecondary : tone.color)
        .labelStyle(TightLabelStyle())
    }

}

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(SWIconButtonStyle())
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

// MARK: - Controls

struct StaticToggle: View {
    let isOn: Bool
    let label: String

    var body: some View {
        Capsule()
            .fill(isOn ? SW.Palette.accent : SW.Palette.track)
            .frame(width: 26, height: 15)
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : SW.Palette.hairline))
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct SWPrimaryButtonStyle: ButtonStyle {
    var isLarge = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isLarge ? 13 : 12, weight: .semibold))
            .foregroundStyle(SW.Palette.onAccent)
            .padding(.horizontal, isLarge ? SW.Space.md + 2 : SW.Space.md)
            .frame(height: isLarge ? 30 : 24)
            .background(
                SW.Palette.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

/// Coral is reserved for actions the user cannot undo from the popover.
struct SWDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            // The accent's on-colour clears 4.5:1 on coral in both themes; white does not in dark.
            .foregroundStyle(SW.Palette.onAccent)
            .padding(.horizontal, SW.Space.md)
            .frame(height: 24)
            .background(
                SW.Palette.critical.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

struct SWSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SW.Palette.textPrimary.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, SW.Space.md)
            .frame(height: 24)
            .background(
                SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous).strokeBorder(SW.Palette.hairline))
            .contentShape(Rectangle())
    }
}

struct SWQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? SW.Palette.textSecondary : SW.Palette.textTertiary)
            .padding(.horizontal, SW.Space.sm)
            .frame(height: 24)
            .background(
                SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 1 : (isHovering ? 0.7 : 0)),
                in: RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

struct SWIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? SW.Palette.textSecondary : SW.Palette.textTertiary.opacity(0.6))
            .background(
                SW.Palette.surfaceRaised.opacity(configuration.isPressed ? 1 : (isHovering && isEnabled ? 0.7 : 0)),
                in: RoundedRectangle(cornerRadius: SW.Radius.small - 2, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SW.Space.xs + 1) {
            configuration.icon
            configuration.title
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SW.Space.xs) {
            configuration.title
            configuration.icon.font(.system(size: 10, weight: .bold))
        }
    }
}

// MARK: - Dates

func relativeDescription(_ date: Date, reference: Date?) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: reference ?? Date())
}
