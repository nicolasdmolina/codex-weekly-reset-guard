import SwiftUI

struct GuardPopoverView: View {
    @ObservedObject var model: GuardAppModel
    var canvasHeight: CGFloat = SW.Size.popoverHeight
    var isStaticRender = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SW.Palette.hairline).frame(height: 1)
            if isStaticRender {
                mainContent
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollView {
                    mainContent
                }
                .scrollIndicators(.automatic)
            }
            Rectangle().fill(SW.Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: SW.Size.popoverWidth, height: canvasHeight)
        .background(SW.Palette.canvas)
        .foregroundStyle(SW.Palette.textPrimary)
        .tint(SW.Palette.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Second Wind")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: SW.Space.md) {
            BrandMark()
            VStack(alignment: .leading, spacing: SW.Space.xxs) {
                Text("Second Wind")
                    .font(.system(size: 15, weight: .semibold))
                Text(headerDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(headerTone == .neutral ? SW.Palette.textSecondary : headerTone.color)
                    .lineLimit(1)
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
            RefreshButton(isChecking: model.isBusyChecking) { model.checkNow() }
                .disabled(model.isBusyChecking || !model.hasAccounts)
        }
        .padding(.horizontal, SW.Space.lg)
        .padding(.vertical, SW.Space.md)
    }

    private var headerTone: SWTone {
        if model.hasAttention { return .critical }
        if model.profiles.contains(where: { $0.status == .nearLimit || $0.status == .confirming })
            || model.claudeProfiles.contains(where: { $0.status == .low }) {
            return .caution
        }
        return .neutral
    }

    private var headerDetail: String {
        let attention = model.attentionCount
        if attention > 0 {
            return attention == 1 ? "1 account needs attention" : "\(attention) accounts need attention"
        }
        if let lowest = model.minimumRemainingPercent {
            return "Lowest headroom \(Int(lowest.rounded()))%"
        }
        return model.hasAccounts ? "Connecting accounts" : "No accounts yet"
    }

    // MARK: Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: SW.Space.lg) {
            if model.isReadOnly {
                NoticeRow(
                    symbol: "eye",
                    text: "Diagnostics mode. Resets, sign-in and launch at login are off.",
                    tone: .neutral
                )
            }
            if let banner = model.banner {
                NoticeRow(symbol: "info.circle", text: banner, tone: .neutral)
            }

            if !model.hasAccounts || model.isShowingAddProfile {
                EnrollmentPanel(model: model, isStaticRender: isStaticRender)
            }

            if !model.profiles.isEmpty {
                AccountSection(title: "Codex", detail: "Auto-redeem at 3%") {
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { RowDivider() }
                        CodexAccountRow(
                            profile: profile,
                            isStaticRender: isStaticRender,
                            isReadOnly: model.isReadOnly,
                            referenceDate: model.referenceDate,
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
                            isStaticRender: isStaticRender,
                            isReadOnly: model.isReadOnly,
                            referenceDate: model.referenceDate,
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
        .animation(SW.Motion.easeOut(SW.Motion.standard, reduceMotion: isStaticRender), value: model.isShowingAddProfile)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: SW.Space.sm) {
            if model.hasAccounts && !model.isShowingAddProfile && !model.isReadOnly {
                Button {
                    model.enrollmentError = nil
                    model.isShowingAddProfile = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(SWQuietButtonStyle())
            }
            Spacer()
            if let checked = model.lastCheckedAt {
                Text("Checked \(relative(checked))")
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
                if !model.claudeProfiles.isEmpty {
                    Button("Open Claude usage settings") { model.openClaudeUsage() }
                    Divider()
                }
                Button(LaunchAtLogin.isEnabled ? "Turn off launch at login" : "Launch at login") {
                    do {
                        let shouldEnable = !LaunchAtLogin.isEnabled
                        try LaunchAtLogin.setEnabled(shouldEnable)
                        model.banner = shouldEnable ? "Second Wind opens at login." : "Launch at login is off."
                    } catch {
                        model.banner = "Could not change launch at login. Try again from System Settings › General › Login Items."
                    }
                }
                Divider()
                Button("Quit Second Wind") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options")
        }
    }

    private func relative(_ date: Date) -> String {
        relativeDescription(date, reference: model.referenceDate)
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
    @Environment(\.isEnabled) private var isEnabled
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

private struct AccountSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, SW.Space.xs)
            VStack(spacing: 0) { content }
                .background(SW.Palette.surface, in: RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SW.Radius.medium, style: .continuous)
                        .strokeBorder(SW.Palette.hairline)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) accounts")
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(SW.Palette.hairline).frame(height: 1).padding(.leading, SW.Space.md)
    }
}

// MARK: - Rows

private struct RowHeading: View {
    let name: String
    let hint: String
    let badge: String?
    let percent: Double?
    let percentCaption: String
    let tone: SWTone

    var body: some View {
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
                }
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(SW.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SW.Space.sm)
            if let percent {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(percent.rounded(.down)))%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tone == .caution || tone == .critical ? tone.color : SW.Palette.textPrimary)
                        .contentTransition(.numericText(value: percent))
                    Text(percentCaption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SW.Palette.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct StatusLine: View {
    let symbol: String
    let text: String
    let tone: SWTone

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tone == .neutral || tone == .good ? SW.Palette.textSecondary : tone.color)
        .labelStyle(TightLabelStyle())
    }
}

private struct CodexAccountRow: View {
    let profile: GuardProfilePresentation
    let isStaticRender: Bool
    let isReadOnly: Bool
    let referenceDate: Date?
    let onToggle: (Bool) -> Void
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm + 2) {
            RowHeading(
                name: profile.displayName,
                hint: profile.accountHint,
                badge: nil,
                percent: profile.weeklyRemainingPercent,
                percentCaption: "left this week",
                tone: tone
            )

            if let remaining = profile.weeklyRemainingPercent {
                HeadroomMeter(remaining: remaining, threshold: 3, tone: tone, animate: !isStaticRender)
                    .accessibilityLabel("Weekly headroom")
                    .accessibilityValue("\(Int(remaining.rounded())) percent left")
                HStack(spacing: SW.Space.sm) {
                    Text(resetsLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SW.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: SW.Space.xs)
                    if profile.isConnected || profile.autoResetEnabled {
                        Text("Auto-redeem")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SW.Palette.textSecondary)
                        if isStaticRender {
                            StaticToggle(isOn: profile.autoResetEnabled)
                        } else {
                            Toggle("Auto-redeem", isOn: autoResetBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .disabled(isReadOnly || (!profile.isConnected && !profile.autoResetEnabled))
                                .help("Redeem a saved reset after two weekly readings at or below 3% left")
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: SW.Space.sm) {
                StatusLine(symbol: profile.status.symbolName, text: statusText, tone: tone)
                Spacer(minLength: SW.Space.xs)
                if !profile.isConnected && !isReadOnly {
                    Button("Connect", action: onReconnect)
                        .buttonStyle(SWPrimaryButtonStyle())
                }
            }
        }
        .padding(SW.Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.displayName), Codex, \(profile.status.title)")
    }

    private var tone: SWTone {
        switch profile.status {
        case .healthy, .redeeming: .neutral
        case .verified: .good
        case .nearLimit, .confirming: .caution
        case .attention, .disconnected: .critical
        }
    }

    private var resetsLine: String {
        var parts: [String] = []
        let count = profile.availableResetCount
        parts.append(count == 1 ? "1 reset saved" : "\(count) resets saved")
        if let reset = profile.naturalResetAt {
            parts.append("renews \(relativeDescription(reset, reference: referenceDate))")
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        if profile.detail.isEmpty { return profile.status.title }
        if !profile.isConnected { return profile.detail }
        return "\(profile.status.title). \(profile.detail)"
    }

    private var autoResetBinding: Binding<Bool> {
        Binding(get: { profile.autoResetEnabled }, set: { onToggle($0) })
    }
}

private struct ClaudeAccountRow: View {
    let profile: ClaudeProfilePresentation
    let isStaticRender: Bool
    let isReadOnly: Bool
    let referenceDate: Date?
    let onConnect: () -> Void
    let onCancel: () -> Void
    let onOpenUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.sm + 2) {
            RowHeading(
                name: profile.displayName,
                hint: profile.accountHint,
                badge: profile.planName,
                percent: profile.tightestWindow?.remainingPercent,
                percentCaption: profile.tightestWindow.map { "left · \($0.label.lowercased())" } ?? "",
                tone: tone
            )

            if !profile.windows.isEmpty {
                VStack(spacing: SW.Space.sm) {
                    ForEach(profile.windows) { window in
                        WindowRow(window: window, referenceDate: referenceDate, animate: !isStaticRender)
                    }
                }
            }

            HStack(alignment: .center, spacing: SW.Space.sm) {
                StatusLine(symbol: profile.status.symbolName, text: statusText, tone: tone)
                Spacer(minLength: SW.Space.xs)
                actions
            }
        }
        .padding(SW.Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.displayName), Claude, \(profile.status.title)")
    }

    @ViewBuilder
    private var actions: some View {
        if isReadOnly {
            EmptyView()
        } else {
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

    private var tone: SWTone {
        switch profile.status {
        case .healthy, .checking, .signingIn: .neutral
        case .low: .caution
        case .signedOut, .attention: .critical
        }
    }

    private var statusText: String {
        switch profile.status {
        case .healthy: profile.detail
        default: profile.detail.isEmpty ? profile.status.title : profile.detail
        }
    }
}

private struct WindowRow: View {
    let window: ClaudeWindowPresentation
    let referenceDate: Date?
    let animate: Bool

    var body: some View {
        HStack(spacing: SW.Space.sm) {
            Text(window.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SW.Palette.textSecondary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            HeadroomMeter(
                remaining: window.remainingPercent,
                threshold: ClaudeProfilePresentation.lowThresholdPercent,
                tone: window.remainingPercent <= ClaudeProfilePresentation.lowThresholdPercent ? .caution : .neutral,
                animate: animate
            )
            HStack(spacing: SW.Space.xs - 1) {
                if window.resetsAt != nil {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                Text(resetText)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(SW.Palette.textTertiary)
            .monospacedDigit()
            .frame(width: 92, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) limit")
        .accessibilityValue("\(Int(window.remainingPercent.rounded(.down))) percent left" + (window.resetsAt == nil ? "" : ", resets \(resetText)"))
    }

    private var resetText: String {
        guard let reset = window.resetsAt else { return "\(Int(window.remainingPercent.rounded(.down)))% left" }
        return shortResetDescription(reset, reference: referenceDate)
    }
}

/// The signature element: a capsule of remaining headroom with a tick at the alert line. When a
/// reset lands, the fill sweeps back to full on the slow motion token.
private struct HeadroomMeter: View {
    let remaining: Double
    let threshold: Double
    let tone: SWTone
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = max(0, min(100, remaining)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(SW.Palette.track)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(fraction > 0 ? SW.Size.meterHeight : 0, width * fraction))
                Rectangle()
                    .fill(SW.Palette.textTertiary.opacity(0.7))
                    .frame(width: 1, height: SW.Size.meterHeight + 4)
                    .offset(x: width * threshold / 100)
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: SW.Size.meterHeight + 4)
        .animation(animate ? SW.Motion.easeOut(SW.Motion.slow, reduceMotion: reduceMotion) : nil, value: remaining)
        .accessibilityElement()
    }

    private var fillColor: Color {
        switch tone {
        case .caution: SW.Palette.caution
        case .critical: SW.Palette.critical
        case .neutral, .good: SW.Palette.accent
        }
    }
}

// MARK: - Enrollment

private struct EnrollmentPanel: View {
    @ObservedObject var model: GuardAppModel
    let isStaticRender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.md) {
            VStack(alignment: .leading, spacing: SW.Space.xs) {
                Text(model.hasAccounts ? "Add an account" : "Watch your first account")
                    .font(.system(size: 15, weight: .semibold))
                Text(providerExplanation)
                    .font(.system(size: 12))
                    .foregroundStyle(SW.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProviderPicker(selection: $model.enrollmentProvider, isStatic: isStaticRender)

            VStack(alignment: .leading, spacing: SW.Space.sm) {
                field(
                    label: "Email",
                    placeholder: "you@example.com",
                    text: $model.profileEmail,
                    accessibility: "\(model.enrollmentProvider.title) account email"
                )
                field(
                    label: "Name",
                    placeholder: "Personal, work…",
                    text: $model.profileDisplayName,
                    accessibility: "Account name, optional"
                )
            }

            if let error = model.enrollmentError {
                StatusLine(symbol: "exclamationmark.circle.fill", text: error, tone: .critical)
            }

            HStack(spacing: SW.Space.sm) {
                Button(model.isAddingProfile ? "Adding…" : "Add \(model.enrollmentProvider.title) account") {
                    model.addProfile()
                }
                .buttonStyle(SWPrimaryButtonStyle(isLarge: true))
                .disabled(!model.isReady || model.isAddingProfile || model.isReadOnly)
                .keyboardShortcut(.defaultAction)
                if model.hasAccounts {
                    Button("Cancel") { model.isShowingAddProfile = false }
                        .buttonStyle(SWQuietButtonStyle())
                        .disabled(model.isAddingProfile)
                }
            }
        }
        .padding(SW.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SW.Palette.surface, in: RoundedRectangle(cornerRadius: SW.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SW.Radius.large, style: .continuous)
                .strokeBorder(SW.Palette.hairline)
        }
    }

    private var providerExplanation: String {
        switch model.enrollmentProvider {
        case .codex:
            "Signs in to Codex in its own private folder. Auto-redeem starts off; turn it on per account."
        case .claude:
            "Signs in to Claude Code in its own private folder and reads /usage. Alerts you at 10% left."
        }
    }

    @ViewBuilder
    private func field(label: String, placeholder: String, text: Binding<String>, accessibility: String) -> some View {
        HStack(spacing: SW.Space.sm) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SW.Palette.textSecondary)
                .frame(width: 44, alignment: .leading)
            if isStaticRender {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(SW.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SW.Space.sm)
                    .frame(height: 28)
                    .background(SW.Palette.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SW.Palette.hairline))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(label == "Email" ? .emailAddress : nil)
                    .accessibilityLabel(accessibility)
                    .onSubmit { model.addProfile() }
            }
        }
    }
}

private struct ProviderPicker: View {
    @Binding var selection: ProviderKind
    let isStatic: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: SW.Space.xxs) {
            ForEach(ProviderKind.allCases) { provider in
                let isSelected = provider == selection
                Button {
                    withAnimation(SW.Motion.easeOut(SW.Motion.quick, reduceMotion: reduceMotion || isStatic)) {
                        selection = provider
                    }
                } label: {
                    Text(provider.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? SW.Palette.textPrimary : SW.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(SW.Palette.surfaceRaised)
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
        .background(SW.Palette.canvas, in: RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Service")
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

private struct NoticeRow: View {
    let symbol: String
    let text: String
    let tone: SWTone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SW.Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(SW.Palette.textSecondary)
        .padding(.horizontal, SW.Space.md)
        .padding(.vertical, SW.Space.sm + 2)
        .background(SW.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: SW.Radius.small, style: .continuous))
    }
}

// MARK: - Controls

private struct StaticToggle: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? SW.Palette.accent : SW.Palette.track)
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .accessibilityLabel("Auto-redeem")
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

private struct TightLabelStyle: LabelStyle {
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

/// "9:40 PM" today, "Tue 3 AM" this week, "Nov 12" beyond.
func shortResetDescription(_ date: Date, reference: Date?) -> String {
    let now = reference ?? Date()
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    if date.timeIntervalSince(now) < 6 * 86_400 {
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(date.formatted(.dateTime.hour().minute()))"
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
