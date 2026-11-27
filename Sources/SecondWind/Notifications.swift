import AppKit
import Foundation
import SecondWindCore
@preconcurrency import UserNotifications

/// What the router needs from the system notification center. Tests supply a fake.
protocol AlertNotifier: Sendable {
    /// Shows now, or schedules when `delivery.fireAt` is set. Same id replaces.
    func deliver(_ delivery: AlertDelivery, now: Date) async throws
    func cancel(_ ids: [String]) async
    func permission() async -> NotificationPermissionStatus
    func requestPermission() async -> NotificationPermissionStatus
}

enum AlertTestError: Error, Equatable, LocalizedError {
    case unavailable
    case notAllowed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Test notifications work only in the installed app."
        case .notAllowed: "Notifications are off for Second Wind. Turn them on in System Settings."
        }
    }
}

enum AlertPreferencesError: Error, Equatable, LocalizedError {
    case notSaved

    var errorDescription: String? { "The alert setting could not be saved. Try again." }
}

/// The one place notices are decided, deduplicated and handed to the system. Controllers and
/// the quota stream feed it without waiting; one queue applies everything in arrival order.
/// Each `ingest` must carry a loaded provider's full roster: accounts missing from it are
/// forgotten and their pending reminders withdrawn.
actor AlertRouter {
    private enum Job: Sendable {
        case roster(QuotaProvider, [QuotaAccountRecord], [UUID: String])
        case post(AlertPost)
        case forget(AccountRef)
        case preferences(AlertPreferences, CheckedContinuation<Bool, Never>)
        case settle(CheckedContinuation<Void, Never>)
    }

    private let store: SecureStateStore<AlertLedger>?
    private let notifier: any AlertNotifier
    private let now: @Sendable () -> Date
    private nonisolated let jobs: AsyncStream<Job>.Continuation
    private var ledger: AlertLedger?

    init(
        stateURL: URL?,
        notifier: any AlertNotifier,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        store = stateURL.map { SecureStateStore(fileURL: $0, maximumBytes: 256 * 1_024) }
        self.notifier = notifier
        self.now = now
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        Task { [weak self] in
            for await job in stream {
                guard let self else { return }
                await self.run(job)
            }
        }
    }

    deinit {
        jobs.finish()
    }

    nonisolated func ingest(
        _ provider: QuotaProvider,
        records: [QuotaAccountRecord],
        names: [UUID: String] = [:]
    ) {
        jobs.yield(.roster(provider, records, names))
    }

    nonisolated func post(_ post: AlertPost) {
        jobs.yield(.post(post))
    }

    nonisolated func forget(_ account: AccountRef) {
        jobs.yield(.forget(account))
    }

    func settled() async {
        await withCheckedContinuation { jobs.yield(.settle($0)) }
    }

    func preferences() async -> AlertPreferences {
        await settled()
        return ledger?.preferences ?? .off
    }

    func setPreferences(_ preferences: AlertPreferences) async throws {
        guard store != nil else { throw AlertPreferencesError.notSaved }
        // Ask first, so nothing is scheduled into a center that has not been allowed yet.
        if preferences.savedResetExpiry || preferences.limitRefilled,
           await notifier.permission() == .notDetermined {
            _ = await notifier.requestPermission()
        }
        let saved = await withCheckedContinuation { jobs.yield(.preferences(preferences, $0)) }
        guard saved else { throw AlertPreferencesError.notSaved }
    }

    func permission() async -> NotificationPermissionStatus {
        guard store != nil else { return .unknown }
        return await notifier.permission()
    }

    func requestPermission() async -> NotificationPermissionStatus {
        guard store != nil else { return .unknown }
        return await notifier.requestPermission()
    }

    func sendTest() async throws {
        guard store != nil else { throw AlertTestError.unavailable }
        var status = await notifier.permission()
        if status == .notDetermined {
            status = await notifier.requestPermission()
        }
        guard status == .allowed else { throw AlertTestError.notAllowed }
        try await notifier.deliver(
            AlertDelivery(id: "test", account: nil, name: "", notice: .test),
            now: now()
        )
    }

    private func run(_ job: Job) async {
        switch job {
        case let .settle(done):
            done.resume()
        case let .preferences(preferences, done):
            guard store != nil else { return done.resume(returning: false) }
            var next = await currentLedger()
            let plan = AlertPolicy.setPreferences(preferences, ledger: &next, now: now())
            done.resume(returning: await commit(next, plan))
        case let .roster(provider, records, names):
            guard store != nil else { return }
            var next = await currentLedger()
            var plan = AlertPolicy.keepOnly(Set(records.map(\.id)), of: provider, ledger: &next, now: now())
            for record in records {
                let name = names[record.accountID] ?? "\(AccountRef(record).provider.title) account"
                plan += AlertPolicy.ingest(record, name: name, ledger: &next, now: now())
            }
            await commit(next, plan)
        case let .post(post):
            guard store != nil else { return }
            var next = await currentLedger()
            let plan = AlertPolicy.post(post, ledger: &next, now: now())
            await commit(next, plan)
        case let .forget(account):
            guard store != nil else { return }
            var next = await currentLedger()
            let plan = AlertPolicy.forget(account.token, ledger: &next, now: now())
            await commit(next, plan)
        }
    }

    /// Saves the ledger before any notice leaves the app. When the save fails, notices that
    /// rely on the ledger to stay unique are dropped rather than risk repeating after relaunch.
    @discardableResult
    private func commit(_ next: AlertLedger, _ plan: AlertPlan) async -> Bool {
        var saved = true
        if next != ledger {
            do {
                try await store?.save(next)
                ledger = next
            } catch {
                saved = false
            }
        }
        if saved, !plan.cancellations.isEmpty {
            await notifier.cancel(plan.cancellations)
        }
        let deliveries = saved ? plan.deliveries : plan.deliveries.filter { !$0.notice.needsDurableLedger }
        var unscheduled: [String] = []
        for delivery in deliveries {
            do {
                try await notifier.deliver(delivery, now: now())
            } catch {
                if delivery.fireAt != nil { unscheduled.append(delivery.id) }
            }
        }
        // A reminder the system refused (notifications off, for example) is released so the next
        // fresh reading schedules it again. A refused immediate notice stays sent.
        if saved, !unscheduled.isEmpty, var released = ledger {
            for id in unscheduled { released.sent[id] = nil }
            ledger = released
            try? await store?.save(released)
        }
        return saved
    }

    private func currentLedger() async -> AlertLedger {
        if let ledger { return ledger }
        // An unreadable ledger restarts empty with both opt-ins off: nothing can fire from it.
        let loaded = (try? await store?.load()) ?? nil
        let value = loaded ?? AlertLedger()
        ledger = value
        return value
    }
}

@MainActor
func makeAlertRouter(configuration: GuardRuntimeConfiguration) -> AlertRouter {
    // An unbundled `swift run` build has no notification identity, and the center traps there.
    let isLive = configuration.operationMode == .production && Bundle.main.bundleIdentifier != nil
    return AlertRouter(
        stateURL: isLive
            ? configuration.applicationSupportDirectory
                .appendingPathComponent("alerts.json", isDirectory: false)
            : nil,
        notifier: UserNotificationCenterNotifier()
    )
}

/// Notification text. Names the account by its display name only.
enum AlertText {
    static func make(for delivery: AlertDelivery, now: Date) -> (title: String, body: String) {
        let provider = delivery.account?.provider.title ?? "Second Wind"
        let name = delivery.name
        switch delivery.notice {
        case let .lowQuota(window):
            var body = "\(name) has \(Int(window.remainingPercent.rounded(.down)))% left."
            if let resetsAt = window.resetsAt, resetsAt > now {
                body += " Resets \(RelativeDateTimeFormatter().localizedString(for: resetsAt, relativeTo: now))."
            }
            return ("\(provider) \(windowName(window.kind)) limit is low", body)
        case let .remoteLowQuota(window, remoteProvider, deviceName):
            var body = "\(name) on \(deviceName) has \(Int(window.remainingPercent.rounded(.down)))% left."
            if let resetsAt = window.resetsAt, resetsAt > now {
                body += " Resets \(RelativeDateTimeFormatter().localizedString(for: resetsAt, relativeTo: now))."
            }
            return ("\(remoteProvider.title) \(windowName(window.kind)) limit is low", body)
        case let .limitRefilled(kind):
            return (
                "\(provider) \(windowName(kind)) limit refilled",
                "\(provider) confirmed \(name)'s \(windowName(kind)) limit is usable again."
            )
        case let .savedResetExpiring(stage, expiresAt):
            let when = expiresAt.formatted(.dateTime.weekday(.wide).hour().minute())
            let title = switch stage {
            case .dayBefore: "Saved \(provider) reset expires within a day"
            case .hourBefore: "Saved \(provider) reset expires within an hour"
            }
            return (title, "\(name) has a saved reset that expires \(when).")
        case .resetApplied:
            return (
                "\(provider) weekly reset applied",
                "\(name) has its weekly allowance back. Second Wind verified the saved reset."
            )
        case let .needsAttention(reason):
            return switch reason {
            case .resetNeedsAttention: (
                "\(provider) reset needs attention",
                "Second Wind stopped resetting \(name) because it could not verify the last reset."
            )
            case .signInRequired: (
                "\(provider) sign-in expired",
                "Reconnect \(name) to keep monitoring it."
            )
            case .wrongAccount: (
                "Wrong \(provider) account signed in",
                "Reconnect \(name) with the account it expects."
            )
            case .monitoringStopped: (
                "\(provider) monitoring stopped",
                "Second Wind stopped checking \(name) so it cannot spend usage. Reconnect to resume."
            )
            }
        case .test:
            return ("Second Wind notifications are on", "Clicking a notice opens the account it is about.")
        }
    }

    static func windowName(_ kind: QuotaWindowKind) -> String {
        switch kind {
        case .session: "5-hour"
        case .weekly: "weekly"
        case let .modelWeekly(model): "\(model.replacingOccurrences(of: " only", with: "")) weekly"
        }
    }
}

/// The payload a notice carries: only the account token, never an email or credit.
enum AlertRoute {
    static let accountKey = "account"

    static func userInfo(for delivery: AlertDelivery) -> [String: String] {
        delivery.account.map { [accountKey: $0.token] } ?? [:]
    }

    static func account(from userInfo: [AnyHashable: Any]) -> AccountRef? {
        (userInfo[accountKey] as? String).flatMap(AccountRef.init(token:))
    }
}

/// The system notification center. Created lazily per call: it traps without an app bundle,
/// so nothing touches it until the installed app delivers something.
struct UserNotificationCenterNotifier: AlertNotifier {
    static let attentionCategory = "second-wind.attention"
    static let fixAction = "second-wind.fix"

    func deliver(_ delivery: AlertDelivery, now: Date) async throws {
        let text = AlertText.make(for: delivery, now: now)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = AlertRoute.userInfo(for: delivery)
        if let account = delivery.account {
            content.threadIdentifier = account.token
        }
        if case .needsAttention = delivery.notice {
            content.categoryIdentifier = Self.attentionCategory
        }
        let trigger = delivery.fireAt.map { fireAt in
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: fireAt
                ),
                repeats: false
            )
        }
        let request = UNNotificationRequest(identifier: delivery.id, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    func cancel(_ ids: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func permission() async -> NotificationPermissionStatus {
        Self.status(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    func requestPermission() async -> NotificationPermissionStatus {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    static func status(_ status: UNAuthorizationStatus) -> NotificationPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional: .allowed
        @unknown default: .unknown
        }
    }
}

/// Opens the account a clicked notice is about. A notice without an account opens the popover.
final class AlertResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let open: @MainActor @Sendable (AccountRef?) -> Void

    private init(open: @escaping @MainActor @Sendable (AccountRef?) -> Void) {
        self.open = open
    }

    /// The center keeps its delegate weakly; hold the result for the app's lifetime. Install it
    /// before the app finishes launching so a click that launched the app is not lost.
    @MainActor
    static func install(open: @escaping @MainActor @Sendable (AccountRef?) -> Void) -> AlertResponder {
        let responder = AlertResponder(open: open)
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UserNotificationCenterNotifier.attentionCategory,
                actions: [
                    UNNotificationAction(
                        identifier: UserNotificationCenterNotifier.fixAction,
                        title: "Fix",
                        options: [.foreground]
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        center.delegate = responder
        return responder
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let account = AlertRoute.account(from: response.notification.request.content.userInfo)
        await open(account)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

enum NotificationSettingsLink {
    static func url(bundleIdentifier: String?) -> URL {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)"
              )
        else { return fallbackURL }
        return url
    }

    static let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    @MainActor
    static func open() {
        if !NSWorkspace.shared.open(url(bundleIdentifier: Bundle.main.bundleIdentifier)) {
            NSWorkspace.shared.open(fallbackURL)
        }
    }
}
