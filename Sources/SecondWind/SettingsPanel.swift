import SwiftUI

/// Display conventions, opt-in alerts with the notification permission they need, and the
/// login item. Every result stays on this page until the user leaves it, independent of the
/// runtime's banner.
struct SettingsPanel: View {
    @ObservedObject var interface: GuardInterfaceModel
    let isStaticRender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SW.Space.lg) {
            AccountSection(title: "Display", detail: nil) {
                SettingsRow(title: "Show quota as") {
                    SegmentedChoice(
                        selection: $interface.preferences.quota,
                        options: QuotaConvention.allCases,
                        title: \.title,
                        accessibilityLabel: "Show quota as",
                        isStatic: isStaticRender
                    )
                    .frame(width: 176)
                }
                RowDivider()
                SettingsRow(title: "Reset times") {
                    SegmentedChoice(
                        selection: $interface.preferences.resetTimes,
                        options: ResetTimeStyle.allCases,
                        title: \.title,
                        accessibilityLabel: "Reset times",
                        isStatic: isStaticRender
                    )
                    .frame(width: 176)
                }
            }

            VStack(alignment: .leading, spacing: SW.Space.sm) {
                AccountSection(title: "Alerts", detail: nil) {
                    SettingsRow(title: "Saved reset expiring", detail: "Codex · 24 hours and 1 hour before") {
                        alertToggle(\.savedResetExpiry, label: "Saved reset expiring")
                    }
                    RowDivider()
                    SettingsRow(title: "Limit refilled", detail: "Once a used-up limit is confirmed usable") {
                        alertToggle(\.limitRefilled, label: "Limit refilled")
                    }
                    RowDivider()
                    NotificationPermissionRow(interface: interface)
                }
                if let feedback = interface.settingsFeedback {
                    settingsFeedback(feedback)
                        .padding(.horizontal, SW.Space.xs)
                }
            }

            if !interface.isReadOnly {
                VStack(alignment: .leading, spacing: SW.Space.sm) {
                    AccountSection(title: "General", detail: nil) {
                        SettingsRow(title: "Open at login") {
                            if isStaticRender {
                                StaticToggle(isOn: interface.launchAtLogin, label: "Open at login")
                            } else {
                                Toggle("Open at login", isOn: Binding(
                                    get: { interface.launchAtLogin },
                                    set: { interface.setLaunchAtLogin($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            }
                        }
                    }
                    if let error = interface.launchAtLoginError {
                        StatusLine(symbol: "exclamationmark.circle.fill", text: error, tone: .critical)
                            .padding(.horizontal, SW.Space.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func alertToggle(_ keyPath: WritableKeyPath<AlertPreferences, Bool>, label: String) -> some View {
        let isOn = interface.alertPreferences[keyPath: keyPath]
        if isStaticRender {
            StaticToggle(isOn: isOn, label: label)
        } else {
            Toggle(label, isOn: Binding(
                get: { interface.alertPreferences[keyPath: keyPath] },
                set: { interface.setAlert(keyPath, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(interface.isReadOnly || interface.pendingAlertChange
                || (!interface.isPreview && interface.setAlertPreferences == nil))
        }
    }

    @ViewBuilder
    private func settingsFeedback(_ feedback: GuardInterfaceModel.Feedback) -> some View {
        switch feedback {
        case let .failure(message):
            StatusLine(symbol: "exclamationmark.circle.fill", text: message, tone: .critical)
        case let .success(message):
            StatusLine(symbol: "checkmark.circle.fill", text: message, tone: .good)
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: SW.Space.md) {
            VStack(alignment: .leading, spacing: SW.Space.xxs) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SW.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SW.Space.sm)
            control
        }
        .padding(.horizontal, SW.Space.md)
        .padding(.vertical, SW.Space.sm + 2)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

/// What macOS currently allows, with the one action that moves it forward.
private struct NotificationPermissionRow: View {
    @ObservedObject var interface: GuardInterfaceModel

    var body: some View {
        HStack(alignment: .center, spacing: SW.Space.md) {
            VStack(alignment: .leading, spacing: SW.Space.xxs) {
                Text("Notifications")
                    .font(.system(size: 12.5, weight: .medium))
                Label {
                    Text(statusText)
                } icon: {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusTone.color)
                }
                .font(.system(size: 11))
                .foregroundStyle(statusTone == .critical ? statusTone.color : SW.Palette.textSecondary)
                .labelStyle(TightLabelStyle())
            }
            Spacer(minLength: SW.Space.sm)
            action
        }
        .padding(.horizontal, SW.Space.md)
        .padding(.vertical, SW.Space.sm + 2)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var action: some View {
        switch interface.permission {
        case .allowed:
            Button(interface.isSendingTest ? "Sending…" : "Send test") { interface.sendTest() }
                .buttonStyle(SWSecondaryButtonStyle())
                .disabled(interface.isSendingTest || (!interface.isPreview && interface.sendTestNotification == nil))
        case .notDetermined:
            Button("Allow") { interface.allowNotifications() }
                .buttonStyle(SWPrimaryButtonStyle())
                .disabled(!interface.isPreview && interface.requestNotificationPermission == nil)
        case .denied, .unknown:
            Button {
                interface.openSystemNotificationSettings()
            } label: {
                Label("Open Settings", systemImage: "arrow.up.forward")
                    .labelStyle(TrailingSymbolLabelStyle())
            }
            .buttonStyle(SWSecondaryButtonStyle())
            .disabled(!interface.isPreview && interface.openNotificationSettings == nil)
        }
    }

    private var statusText: String {
        switch interface.permission {
        case .allowed: "Allowed"
        case .notDetermined: "Not allowed yet"
        case .denied: "Off for Second Wind"
        case .unknown: "Status unknown"
        }
    }

    private var statusSymbol: String {
        switch interface.permission {
        case .allowed: "checkmark.circle.fill"
        case .notDetermined: "bell"
        case .denied: "bell.slash.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusTone: SWTone {
        switch interface.permission {
        case .allowed: .good
        case .notDetermined, .unknown: .neutral
        case .denied: .critical
        }
    }
}

private struct TrailingSymbolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SW.Space.xs) {
            configuration.title
            configuration.icon.font(.system(size: 9.5, weight: .bold))
        }
    }
}
