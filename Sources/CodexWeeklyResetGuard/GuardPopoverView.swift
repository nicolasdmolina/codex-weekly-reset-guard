import SwiftUI

struct GuardPopoverView: View {
    @ObservedObject var model: GuardAppModel
    var canvasHeight: CGFloat = 560
    var isStaticRender = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isStaticRender {
                mainContent
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    mainContent
                        .padding(12)
                }
            }
            Divider()
            footer
        }
        .frame(width: 380, height: canvasHeight)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex Weekly Reset Guard")
    }

    private var mainContent: some View {
        VStack(spacing: 10) {
            if model.isReadOnly {
                Text("Read-only diagnostic: reset redemption and launch at login are disabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let banner = model.banner {
                Text(banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }

            if model.profiles.isEmpty || model.isShowingAddProfile {
                enrollment
            }

            ForEach(model.profiles) { profile in
                ProfileCard(
                    profile: profile,
                    isPreview: isStaticRender,
                    isReadOnly: model.isReadOnly,
                    referenceDate: model.referenceDate,
                    onToggle: { model.setAutoReset(profileID: profile.id, enabled: $0) },
                    onReconnect: { model.reconnect(profileID: profile.id) }
                )
            }

            if !model.profiles.isEmpty && !model.isShowingAddProfile {
                Button {
                    model.enrollmentError = nil
                    model.isShowingAddProfile = true
                } label: {
                    Label("Add Profile", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.vertical, 3)
            }

            if !model.history.isEmpty {
                history
            }
        }
    }

    private var enrollment: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.profiles.isEmpty ? "Set up your first profile" : "Add a Codex profile")
                .font(.headline)
            Text("Use the email for your ChatGPT account. Each profile has its own secure Codex sign-in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Account email").font(.caption.weight(.medium))
                if isStaticRender {
                    previewField("you@example.com")
                } else {
                    TextField("you@example.com", text: $model.profileEmail)
                        .textContentType(.emailAddress)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Account email")
                        .onSubmit { model.addProfile() }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Profile name (optional)").font(.caption.weight(.medium))
                if isStaticRender {
                    previewField("Personal or work")
                } else {
                    TextField("Personal or work", text: $model.profileDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Profile name, optional")
                        .onSubmit { model.addProfile() }
                }
            }
            if let error = model.enrollmentError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.isAddingProfile ? "Adding…" : "Add Profile") { model.addProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isReady || model.isAddingProfile)
                if !model.profiles.isEmpty {
                    Button("Cancel") { model.isShowingAddProfile = false }
                        .disabled(model.isAddingProfile)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Connect to verify your account", systemImage: "person.crop.circle.badge.checkmark")
                Label("Auto-redeem starts off", systemImage: "switch.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("When you enable Auto-redeem, Guard can spend an available saved reset after two weekly readings at or below 3% remaining.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private func previewField(_ placeholder: String) -> some View {
        Text(placeholder)
            .font(.body)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly Reset Guard")
                    .font(.headline)
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isPreview || model.isReadOnly {
                Text(model.isPreview ? "Preview" : "Read-only")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(14)
    }

    private var headerDetail: String {
        let attentionCount = model.profiles.filter {
            $0.status == .attention || $0.status == .disconnected
        }.count
        if attentionCount > 0 {
            return "\(attentionCount) profile\(attentionCount == 1 ? "" : "s") need\(attentionCount == 1 ? "s" : "") attention"
        }
        if let minimum = model.minimumRemainingPercent {
            return "Lowest weekly balance: \(minimum.formatted(.number.precision(.fractionLength(0))))%"
        } else {
            return model.profiles.isEmpty ? "Your weekly allowance, protected" : "Connect your Codex profiles"
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity")
                .font(.subheadline.weight(.semibold))
            ForEach(model.history.prefix(3)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.summary)
                            .font(.callout)
                        Text("\(event.profileName) · \(event.occurredAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
    }

    private var footer: some View {
        HStack {
            Button {
                model.checkNow()
            } label: {
                Label(model.isChecking ? "Checking…" : "Check Now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isChecking || model.profiles.isEmpty)

            Spacer()

            if model.isReadOnly {
                Button("Quit") { NSApp.terminate(nil) }
            } else if model.isPreview {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("More options")
            } else {
                Menu {
                    Button(LaunchAtLogin.isEnabled ? "Disable Launch at Login" : "Enable Launch at Login") {
                        do {
                            let shouldEnable = !LaunchAtLogin.isEnabled
                            try LaunchAtLogin.setEnabled(shouldEnable)
                            model.banner = shouldEnable ? "Launch at login enabled" : "Launch at login disabled"
                        } catch {
                            model.banner = "Could not change launch-at-login setting"
                        }
                    }
                    Divider()
                    Button("Quit") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(12)
    }
}

private struct ProfileCard: View {
    let profile: GuardProfilePresentation
    let isPreview: Bool
    let isReadOnly: Bool
    let referenceDate: Date?
    let onToggle: (Bool) -> Void
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: profile.status.symbolName)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(profile.accountHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if profile.isConnected || profile.autoResetEnabled {
                    Text("Auto-redeem")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isPreview {
                        StaticToggle(isOn: profile.autoResetEnabled)
                    } else {
                        Toggle("Auto reset", isOn: autoResetBinding)
                            .disabled(isReadOnly)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Automatically redeem after two weekly readings at or below 3% remaining")
                    }
                }
            }

            if let remaining = profile.weeklyRemainingPercent {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(remaining.formatted(.number.precision(.fractionLength(0))))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("weekly remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let resetAt = profile.naturalResetAt {
                        Text("Weekly resets \(relativeDate(resetAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                UsageProgressBar(value: remaining, color: progressColor)
                    .accessibilityLabel("Weekly usage remaining")
                    .accessibilityValue("\(Int(remaining.rounded())) percent")

                HStack {
                    Label("\(profile.availableResetCount) banked reset\(profile.availableResetCount == 1 ? "" : "s")", systemImage: "arrow.counterclockwise.circle")
                    Spacer()
                    if let expiry = profile.nearestResetExpiry {
                        Text("Banked expires \(relativeDate(expiry))")
                            .help(expiry.formatted(date: .complete, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(profile.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isPreview {
                        Text("Connect")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                    } else {
                        Button("Connect", action: onReconnect)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Text(statusSummary)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .padding(12)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.displayName), \(profile.status.title)")
    }

    private var statusColor: Color {
        switch profile.status {
        case .nearLimit, .confirming: .orange
        case .attention: .red
        case .verified: .green
        default: .secondary
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: referenceDate ?? Date())
    }

    private var progressColor: Color {
        switch profile.status {
        case .nearLimit, .confirming:
            return .orange
        case .attention:
            return .red
        case .verified:
            return .green
        default:
            return .accentColor
        }
    }

    private var statusSummary: String {
        if !profile.isConnected || profile.detail.isEmpty {
            return profile.status.title
        }
        return "\(profile.status.title) · \(profile.detail)"
    }

    private var autoResetBinding: Binding<Bool> {
        Binding(
            get: { profile.autoResetEnabled },
            set: { enabled in onToggle(enabled) }
        )
    }
}

private struct StaticToggle: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .padding(2)
            }
            .accessibilityLabel("Auto reset")
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct UsageProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * max(0, min(100, value)) / 100)
                }
        }
        .frame(height: 6)
    }
}
