import AppKit
import UserNotifications

enum ProposalAction {
    case takeBreak
    case snooze
    case skip
}

enum NotificationAuthorization {
    case unknown
    case notDetermined
    case denied
    case allowed
}

/// macOS の通知を出し、通知の選択肢を受け取る。
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private enum ID {
        static let category = "BREAK_PROPOSAL"
        static let takeBreak = "TAKE_BREAK"
        static let snooze = "SNOOZE"
        static let skip = "SKIP"
        /// 初回の通知と再通知で同じ識別子を使い、通知が重ならないようにする
        static let request = "break-proposal"
        static let breakOver = "break-over"
    }

    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: NotificationAuthorization = .unknown

    var onAction: ((ProposalAction) -> Void)?
    /// 提案の通知の本文がクリックされた。メニューバーのメニューを開き、選択肢を見せる
    var onOpenChoices: (() -> Void)?
    var onAuthorizationChange: (() -> Void)?

    func setUp() {
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: ID.takeBreak, title: "今休む", options: []),
            UNNotificationAction(identifier: ID.snooze, title: "10分後", options: []),
            UNNotificationAction(identifier: ID.skip, title: "今回はスキップ", options: []),
        ]
        let category = UNNotificationCategory(
            identifier: ID.category,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
        requestAuthorization()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                NSLog("BreakTrigger: 通知の許可の要求に失敗: \(error.localizedDescription)")
            }
            NSLog("BreakTrigger: 通知の許可: \(granted)")
            self?.refreshAuthorization()
        }
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            let state: NotificationAuthorization
            switch settings.authorizationStatus {
            case .notDetermined: state = .notDetermined
            case .denied: state = .denied
            case .authorized, .provisional: state = .allowed
            @unknown default: state = .allowed
            }
            DispatchQueue.main.async {
                guard let self, self.authorization != state else { return }
                self.authorization = state
                self.onAuthorizationChange?()
            }
        }
    }

    func postProposal(isReminder: Bool, workMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = isReminder ? "10分経ちました。休憩しませんか？" : "休憩しませんか？"
        content.body = "最後の休憩から\(workMinutes)分作業しています。クリックすると選択肢を表示します。"
        content.categoryIdentifier = ID.category
        content.sound = .default

        center.removeDeliveredNotifications(withIdentifiers: [ID.request])
        let request = UNNotificationRequest(identifier: ID.request, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("BreakTrigger: 通知を出せませんでした: \(error.localizedDescription)")
            } else {
                NSLog("BreakTrigger: 通知を出しました（\(isReminder ? "再通知" : "初回")）")
            }
        }
    }

    func postBreakOver() {
        let content = UNMutableNotificationContent()
        content.title = "休憩が終わりました"
        content.body = "作業を再開しましょう。"
        content.sound = .default

        center.removeDeliveredNotifications(withIdentifiers: [ID.breakOver])
        let request = UNNotificationRequest(identifier: ID.breakOver, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("BreakTrigger: 通知を出せませんでした: \(error.localizedDescription)")
            } else {
                NSLog("BreakTrigger: 休憩の終わりを通知しました")
            }
        }
    }

    func withdrawProposal() {
        center.removeDeliveredNotifications(withIdentifiers: [ID.request])
        center.removePendingNotificationRequests(withIdentifiers: [ID.request])
    }

    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action: ProposalAction?
        switch response.actionIdentifier {
        // 休憩の終わりの通知には選択肢がないため、何もしない
        case _ where response.notification.request.identifier == ID.breakOver: action = nil
        case ID.takeBreak: action = .takeBreak
        case ID.snooze: action = .snooze
        // 通知を閉じた場合は、今回の提案を閉じる「今回はスキップ」として扱う
        case ID.skip, UNNotificationDismissActionIdentifier: action = .skip
        default: action = nil
        }
        // 本文のクリックでは、メニューバーのメニューを開いて選択肢を見せる
        let opensChoices = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            && response.notification.request.identifier == ID.request
        DispatchQueue.main.async { [weak self] in
            if let action { self?.onAction?(action) }
            if opensChoices { self?.onOpenChoices?() }
            completionHandler()
        }
    }
}
