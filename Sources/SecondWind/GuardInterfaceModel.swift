import AppKit
import Combine
import Foundation

enum NotificationPermissionStatus: Equatable, Sendable {
    /// Not read yet.
    case unknown
    /// Never asked.
    case notDetermined
    /// Off in System Settings.
    case denied
    /// Authorized, provisional or ephemeral.
    case allowed
}

struct AlertPreferences: Equatable, Sendable {
    /// A day and an hour before a saved Codex reset expires.
    var savedResetExpiry: Bool
    /// Once a used-up window is confirmed usable again.
    var limitRefilled: Bool

    static let off = AlertPreferences(savedResetExpiry: false, limitRefilled: false)
}

/// Sync with the user's other Macs through iCloud Drive. Off unless the user turns it on.
enum SyncStatus: Equatable, Sendable {
    case off
    case on
    /// iCloud Drive is not on for this Mac.
    case unavailable
    /// This Mac publishes but cannot read the folder, so other Macs cannot change it.
    case readFailed
    case failed(String)
}

/// Whether a provider's saved accounts have loaded since launch. A provider that failed to load
/// must never count toward "all clear", and a notification target on it is unavailable, not gone.
enum ProviderLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

/// What a notification click asks the popover to show, and how far that request has got.
enum RevealResolution: Equatable, Sendable {
    case waiting
    case found
    /// The provider loaded and the account is not among its accounts.
    case missing
    /// The provider could not load, so Second Wind cannot tell whether the account exists.
    case unavailable(String)

    /// `published` is true once the provider has put its saved account list on screen, which
    /// can happen before its start-up finishes. Before that, an empty list means "not loaded
    /// yet", not "removed".
    static func resolve(
        target: AccountRef,
        present: Set<AccountRef>,
        load: ProviderLoadState,
        published: Bool
    ) -> RevealResolution {
        if present.contains(target) { return .found }
        switch load {
        case let .failed(reason): return .unavailable(reason)
        case .loaded: return .missing
        case .loading: return published ? .missing : .waiting
        }
    }
}

/// UI state and user actions that belong to the popover rather than to quota data: the open
/// page, display preferences, inline account editing, persistent feedback, notification
/// settings and notification navigation. Live callbacks are wired by the app; previews and
/// diagnostics never call them.
@MainActor
final class GuardInterfaceModel: ObservableObject {
    enum Page: Equatable {
        case accounts
        case settings
    }

    enum AccountEditor: Equatable {
        case renaming(AccountRef)
        case confirmingRemoval(AccountRef)

        var account: AccountRef {
            switch self {
            case let .renaming(account), let .confirmingRemoval(account): account
            }
        }
    }

    enum Feedback: Equatable {
        case failure(String)
        case success(String)
    }

    struct Notice: Identifiable, Equatable {
        let id: UUID
        let text: String
        let symbol: String
        let tone: SWTone
    }

    @Published var page: Page = .accounts
    @Published var preferences: DisplayPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: preferenceDefaults)
        }
    }
    @Published private(set) var editor: AccountEditor?
    @Published var draftName = ""
    @Published private(set) var busyAccounts = Set<AccountRef>()
    @Published private(set) var accountFeedback: [AccountRef: Feedback] = [:]
    @Published private(set) var notices: [Notice] = []
    @Published private(set) var transientNotice: String?
    /// Accounts whose saved-reset expiry list is open.
    @Published private(set) var expandedInventories = Set<AccountRef>()

    @Published private(set) var providerStates: [ProviderKind: ProviderLoadState]
    private var providerNotices: [ProviderKind: UUID] = [:]
    @Published private(set) var pendingReveal: AccountRef?
    @Published private(set) var highlighted: AccountRef?
    /// The row the scroll view should bring into view. The view clears it once scrolled.
    @Published var scrollTarget: AccountRef?

    @Published private(set) var permission: NotificationPermissionStatus
    @Published private(set) var alertPreferences: AlertPreferences
    @Published private(set) var pendingAlertChange = false
    @Published private(set) var isSendingTest = false
    @Published private(set) var settingsFeedback: Feedback?
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var syncEnabled: Bool
    @Published private(set) var syncStatus: SyncStatus

    let isPreview: Bool
    let isReadOnly: Bool
    /// Matches the runtime's enrollment limits, so the field never accepts a name it would cut.
    static func maximumNameLength(for provider: ProviderKind) -> Int {
        switch provider {
        case .codex: 60
        case .claude: 48
        }
    }
    static let highlightDuration: TimeInterval = 2.4

    var renameAccount: ((AccountRef, String) async throws -> Void)?
    var removeAccount: ((AccountRef) async throws -> Void)?
    var readNotificationPermission: (() async -> NotificationPermissionStatus)?
    var requestNotificationPermission: (() async -> NotificationPermissionStatus)?
    var openNotificationSettings: (() -> Void)?
    var sendTestNotification: (() async throws -> Void)?
    var readAlertPreferences: (() async -> AlertPreferences)?
    var setAlertPreferences: ((AlertPreferences) async throws -> Void)?
    var preflightCommand: ((AccountRef) -> String?)?
    /// True when removing the account keeps an unresolved Codex reset record for re-enrollment.
    var removalKeepsResetRecord: ((AccountRef) -> Bool)?
    var changeSync: ((Bool) -> Void)?

    private let preferenceDefaults: UserDefaults?
    private let readLaunchAtLogin: () -> Bool
    private let writeLaunchAtLogin: (Bool) throws -> Void
    private var highlightTask: Task<Void, Never>?
    private var transientTask: Task<Void, Never>?
    private weak var attachedModel: GuardAppModel?
    private var modelSubscription: AnyCancellable?

    init(
        isPreview: Bool,
        isReadOnly: Bool,
        preferenceDefaults: UserDefaults?,
        preferences: DisplayPreferences? = nil,
        permission: NotificationPermissionStatus = .unknown,
        alertPreferences: AlertPreferences = .off,
        launchAtLogin: (read: () -> Bool, write: (Bool) throws -> Void)? = nil,
        syncStatus: SyncStatus? = nil
    ) {
        self.isPreview = isPreview
        self.isReadOnly = isReadOnly
        self.providerStates = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map {
            ($0, isPreview ? ProviderLoadState.loaded : .loading)
        })
        self.preferenceDefaults = isPreview ? nil : preferenceDefaults
        self.preferences = preferences ?? DisplayPreferences.load(from: isPreview ? nil : preferenceDefaults)
        self.permission = permission
        self.alertPreferences = alertPreferences
        self.readLaunchAtLogin = launchAtLogin?.read ?? { false }
        self.writeLaunchAtLogin = launchAtLogin?.write ?? { _ in }
        self.launchAtLogin = launchAtLogin?.read() ?? false
        let syncSaved = isPreview ? false : preferenceDefaults?.bool(forKey: Self.syncKey) ?? false
        let status = syncStatus ?? (syncSaved ? .on : .off)
        self.syncStatus = status
        self.syncEnabled = status != .off
    }

    private static let syncKey = "sync.enabled"

    /// The app's live configuration: preferences in the standard defaults and the real login item.
    static func live(isReadOnly: Bool) -> GuardInterfaceModel {
        GuardInterfaceModel(
            isPreview: false,
            isReadOnly: isReadOnly,
            preferenceDefaults: .standard,
            launchAtLogin: isReadOnly ? nil : (read: { LaunchAtLogin.isEnabled }, write: { try LaunchAtLogin.setEnabled($0) })
        )
    }

    var canEditAccounts: Bool { !isReadOnly }

    // MARK: Display

    func toggleResetTimeStyle() {
        preferences.resetTimes = preferences.resetTimes.toggled
    }

    // MARK: Pages

    func showSettings() {
        cancelEditing()
        page = .settings
        settingsFeedback = nil
        launchAtLoginError = nil
        launchAtLogin = readLaunchAtLogin()
        Task { await refreshNotificationSettings() }
    }

    func showAccounts() {
        page = .accounts
        settingsFeedback = nil
    }

    // MARK: Rename and remove

    func beginRename(_ account: AccountRef, currentName: String) {
        guard canEditAccounts else { return }
        editor = .renaming(account)
        draftName = currentName
        accountFeedback[account] = nil
    }

    func confirmRemoval(_ account: AccountRef) {
        guard canEditAccounts else { return }
        editor = .confirmingRemoval(account)
        accountFeedback[account] = nil
    }

    func cancelEditing() {
        guard let editor, !busyAccounts.contains(editor.account) else { return }
        accountFeedback[editor.account] = nil
        self.editor = nil
    }

    func commitRename(currentName: String) {
        guard case let .renaming(account) = editor, !busyAccounts.contains(account) else { return }
        let name = Self.normalizedName(draftName)
        guard name.contains(where: { $0.isLetter || $0.isNumber }) else {
            accountFeedback[account] = .failure("Enter a name with at least one letter or number.")
            return
        }
        guard name != currentName else {
            editor = nil
            return
        }
        guard !isPreview else {
            accountFeedback[account] = .failure("Preview only. Names change in the installed app.")
            return
        }
        guard let renameAccount else {
            accountFeedback[account] = .failure("Renaming is not available in this build.")
            return
        }
        run(account) { [weak self] in
            try await renameAccount(account, name)
            self?.editor = nil
        } failure: { "Could not rename this account. \(Self.recovery($0))" }
    }

    func remove(_ account: AccountRef, displayName: String) {
        guard editor == .confirmingRemoval(account), !busyAccounts.contains(account) else { return }
        guard !isPreview else {
            accountFeedback[account] = .failure("Preview only. Accounts are removed in the installed app.")
            return
        }
        guard let removeAccount else {
            accountFeedback[account] = .failure("Removing accounts is not available in this build.")
            return
        }
        run(account) { [weak self] in
            try await removeAccount(account)
            self?.editor = nil
            self?.accountFeedback[account] = nil
            self?.showTransient("Removed \(displayName).")
        } failure: { "Could not remove \(displayName). \(Self.recovery($0))" }
    }

    private func run(
        _ account: AccountRef,
        _ operation: @escaping @MainActor () async throws -> Void,
        failure: @escaping @MainActor (Error) -> String
    ) {
        busyAccounts.insert(account)
        accountFeedback[account] = nil
        Task { @MainActor in
            defer { busyAccounts.remove(account) }
            do {
                try await operation()
            } catch {
                accountFeedback[account] = .failure(failure(error))
            }
        }
    }

    /// Trims and collapses whitespace the way the runtime stores names, so "same name" is exact.
    static func normalizedName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Keeps the rename field within the provider's limit as the user types.
    func limitDraft(for provider: ProviderKind) {
        let limit = Self.maximumNameLength(for: provider)
        if draftName.count > limit { draftName = String(draftName.prefix(limit)) }
    }

    func removalKeepsResetRecord(for account: AccountRef) -> Bool {
        removalKeepsResetRecord?(account) ?? false
    }

    private static func recovery(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Try again."
    }

    // MARK: Pre-job check

    func preflightCommand(for account: AccountRef) -> String? {
        guard !isReadOnly else { return nil }
        return preflightCommand?(account)
    }

    func copyPreflightCommand(for account: AccountRef) {
        guard !isPreview else {
            accountFeedback[account] = .success("Preview only. Nothing was copied.")
            return
        }
        guard let command = preflightCommand(for: account) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command, forType: .string) else {
            accountFeedback[account] = .failure("Could not copy the check. Try again.")
            return
        }
        accountFeedback[account] = .success("Pre-job check copied. Paste it in Terminal before a long job.")
    }

    func toggleInventoryDetail(_ account: AccountRef) {
        if expandedInventories.remove(account) == nil { expandedInventories.insert(account) }
    }

    func dismissFeedback(for account: AccountRef) {
        accountFeedback[account] = nil
    }

    // MARK: Persistent feedback

    /// Shows an account's failure on its row until the user retries or dismisses it.
    func reportFailure(_ message: String, for account: AccountRef) {
        accountFeedback[account] = .failure(message)
    }

    /// Shows a message at the top of the popover until the user dismisses it.
    @discardableResult
    func reportNotice(_ message: String, symbol: String = "exclamationmark.circle.fill", tone: SWTone = .critical) -> UUID {
        notices.removeAll { $0.text == message }
        let id = UUID()
        notices.append(Notice(id: id, text: message, symbol: symbol, tone: tone))
        return id
    }

    func dismissNotice(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    private func showTransient(_ text: String) {
        transientNotice = text
        transientTask?.cancel()
        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    // MARK: Notification navigation

    /// Follows the app model so a held reveal resolves as soon as its provider loads.
    func attach(_ model: GuardAppModel) {
        attachedModel = model
        // objectWillChange fires before the change lands; the main-queue hop reads it after.
        modelSubscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.resolvePendingReveal() }
            }
        resolvePendingReveal()
    }

    var allProvidersLoaded: Bool {
        providerStates.values.allSatisfy { $0 == .loaded }
    }

    var failedProviders: [(ProviderKind, String)] {
        ProviderKind.allCases.compactMap { provider in
            if case let .failed(reason) = providerStates[provider] { return (provider, reason) }
            return nil
        }
    }

    func providerDidLoad(_ provider: ProviderKind) {
        if let notice = providerNotices.removeValue(forKey: provider) { dismissNotice(notice) }
        providerStates[provider] = .loaded
        resolvePendingReveal()
    }

    func providerDidFail(_ provider: ProviderKind, reason: String) {
        if let notice = providerNotices[provider] { dismissNotice(notice) }
        providerStates[provider] = .failed(reason)
        providerNotices[provider] = reportNotice("\(provider.title) accounts could not load. \(reason)")
        resolvePendingReveal()
    }

    func reveal(_ target: AccountRef) {
        cancelEditing()
        page = .accounts
        pendingReveal = target
        resolvePendingReveal()
    }

    func resolvePendingReveal() {
        guard let target = pendingReveal, let model = attachedModel else { return }
        let present = Set(
            model.profiles.compactMap { AccountRef(provider: .codex, rawID: $0.id) }
                + model.claudeProfiles.compactMap { AccountRef(provider: .claude, rawID: $0.id) }
        )
        let published = switch target.provider {
        case .codex: model.isReady
        case .claude: !model.claudeProfiles.isEmpty
        }
        switch RevealResolution.resolve(
            target: target,
            present: present,
            load: providerStates[target.provider] ?? .loading,
            published: published
        ) {
        case .waiting:
            return
        case .found:
            pendingReveal = nil
            scrollTarget = target
            highlight(target)
        case .missing:
            pendingReveal = nil
            reportNotice(
                "That \(target.provider.title) account is no longer in Second Wind.",
                symbol: "questionmark.circle",
                tone: .neutral
            )
        case .unavailable:
            // The load failure already has its own notice with the reason.
            pendingReveal = nil
            reportNotice(
                "Could not open that \(target.provider.title) account because its accounts did not load.",
                symbol: "exclamationmark.circle.fill",
                tone: .critical
            )
        }
    }

    func cancelPendingReveal() {
        pendingReveal = nil
    }

    private func highlight(_ target: AccountRef) {
        highlighted = target
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.highlightDuration))
            guard !Task.isCancelled else { return }
            self?.highlighted = nil
        }
    }

    /// Static previews pin states that are normally reached through timers or async results.
    func stagePreview(highlight: AccountRef? = nil, settingsFeedback: Feedback? = nil) {
        precondition(isPreview, "Only synthetic previews stage interface state.")
        if let highlight { highlighted = highlight }
        if let settingsFeedback { self.settingsFeedback = settingsFeedback }
    }

    // MARK: Notifications and alerts

    func refreshNotificationSettings() async {
        guard !isPreview else { return }
        if let readNotificationPermission {
            permission = await readNotificationPermission()
        }
        if let readAlertPreferences {
            alertPreferences = await readAlertPreferences()
        }
    }

    func allowNotifications() {
        guard !isPreview else {
            settingsFeedback = .success("Preview only. No permission was requested.")
            return
        }
        Task { @MainActor in
            if let requestNotificationPermission {
                permission = await requestNotificationPermission()
            }
            if permission == .denied {
                settingsFeedback = .failure("Notifications are off for Second Wind. Turn them on in System Settings.")
            }
        }
    }

    func openSystemNotificationSettings() {
        guard !isPreview else {
            settingsFeedback = .success("Preview only. System Settings opens from the installed app.")
            return
        }
        openNotificationSettings?()
    }

    func sendTest() {
        guard !isSendingTest else { return }
        guard !isPreview else {
            settingsFeedback = .success("Preview only. No notification was sent.")
            return
        }
        guard let sendTestNotification else { return }
        isSendingTest = true
        settingsFeedback = nil
        Task { @MainActor in
            defer { isSendingTest = false }
            if permission == .notDetermined || permission == .unknown, let requestNotificationPermission {
                permission = await requestNotificationPermission()
            }
            guard permission == .allowed else {
                settingsFeedback = .failure("Notifications are off for Second Wind. Turn them on in System Settings, then send the test again.")
                return
            }
            do {
                try await sendTestNotification()
                settingsFeedback = .success("Test sent. It should appear in the top-right corner of your screen.")
            } catch {
                settingsFeedback = .failure("The test did not send. \(Self.recovery(error))")
            }
        }
    }

    func setAlert(_ keyPath: WritableKeyPath<AlertPreferences, Bool>, enabled: Bool) {
        guard !isReadOnly, !pendingAlertChange else { return }
        var next = alertPreferences
        next[keyPath: keyPath] = enabled
        guard !isPreview else {
            alertPreferences = next
            return
        }
        guard let setAlertPreferences else { return }
        pendingAlertChange = true
        settingsFeedback = nil
        Task { @MainActor in
            defer { pendingAlertChange = false }
            if enabled, permission == .notDetermined || permission == .unknown, let requestNotificationPermission {
                permission = await requestNotificationPermission()
            }
            do {
                // Persistence-led like auto-redeem: the switch moves only after the change is saved.
                try await setAlertPreferences(next)
                alertPreferences = next
                if enabled, permission == .denied {
                    settingsFeedback = .failure("Alert saved. Turn on notifications for Second Wind in System Settings to get it.")
                }
            } catch {
                settingsFeedback = .failure("Could not save the alert setting. \(Self.recovery(error))")
            }
        }
    }

    // MARK: Sync

    func setSyncEnabled(_ enabled: Bool) {
        guard !isReadOnly, enabled != syncEnabled else { return }
        syncEnabled = enabled
        syncStatus = enabled ? .on : .off
        guard !isPreview else { return }
        preferenceDefaults?.set(enabled, forKey: Self.syncKey)
        changeSync?(enabled)
    }

    func updateSyncStatus(_ status: SyncStatus) {
        guard syncEnabled || status == .off else { return }
        syncStatus = status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isReadOnly else { return }
        guard !isPreview else {
            launchAtLogin = enabled
            return
        }
        do {
            try writeLaunchAtLogin(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change this. Try again from System Settings › General › Login Items."
        }
        launchAtLogin = readLaunchAtLogin()
    }
}
