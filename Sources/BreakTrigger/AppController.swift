import AppKit
import BreakTriggerCore
import Combine

/// エンジン、通知、メニューバーをつなぐ。
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let notifications = NotificationController()
    private lazy var settingsWindow = SettingsWindowController(store: store)
    private var engine: BreakEngine!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var ticks = 0

    /// 画面の状態。すべて false のときに「画面がついている」とみなす
    private var isDisplayAsleep = false
    private var isSystemAsleep = false
    private var isLocked = false
    private var isSessionInactive = false

    /// メニューを開いている間も更新する項目
    private var durationItem: NSMenuItem?
    private var statusLineItem: NSMenuItem?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 動作確認用：BREAK_TRIGGER_TIME_SCALE=60 なら、50分を50秒、10分を10秒として扱う
        var timing = EngineTiming()
        if let raw = ProcessInfo.processInfo.environment["BREAK_TRIGGER_TIME_SCALE"],
           let scale = Double(raw), scale > 0 {
            timing = .scaled(by: scale)
            NSLog("BreakTrigger: 時間を \(scale) 分の1に縮めて動かします")
        }
        engine = BreakEngine(settings: store.settings, timing: timing, now: Date())

        store.$settings
            .sink { [weak self] settings in self?.engine?.settings = settings }
            .store(in: &cancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.onAuthorizationChange = { [weak self] in self?.updateIcon() }
        notifications.onOpenChoices = { [weak self] in
            // 通知の処理が終わってからメニューを開く
            DispatchQueue.main.async { self?.statusItem.button?.performClick(nil) }
        }
        notifications.setUp()

        observeScreen()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()

        // 動作確認用：起動と同時に設定のウインドウを開く
        if ProcessInfo.processInfo.environment["BREAK_TRIGGER_OPEN_SETTINGS"] == "1" {
            settingsWindow.show()
        }
    }

    // MARK: - 画面の状態

    /// ディスプレイのスリープ、Macのスリープ、画面のロック、ユーザの切り替えを見張る。
    private func observeScreen() {
        let workspace = NSWorkspace.shared.notificationCenter
        let observe: (NotificationCenter, Notification.Name, @escaping (AppController) -> Void) -> Void = { center, name, change in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                NSLog("BreakTrigger: \(name.rawValue)")
                change(self)
                self.updateScreenState()
            }
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.isDisplayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.isDisplayAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.isSystemAsleep = false
            $0.notifications.refreshAuthorization()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionInactive = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
    }

    private func updateScreenState() {
        let isOn = !(isDisplayAsleep || isSystemAsleep || isLocked || isSessionInactive)
        guard isOn != engine.isScreenOn else { return }
        let now = Date()
        apply(isOn ? engine.handleScreenOn(now: now) : engine.handleScreenOff(now: now))
        updateLiveMenuItems()
    }

    // MARK: - 時間の経過

    private func tick() {
        let before = engine.phase
        apply(engine.tick(now: Date(), idle: ActivityMonitor.secondsSinceLastInput()))
        if engine.phase != before {
            NSLog("BreakTrigger: 状態 \(before) → \(engine.phase)")
        }
        ticks += 1
        if ticks % 30 == 0 {
            notifications.refreshAuthorization()
        }
        updateIcon()
        updateLiveMenuItems()
    }

    private func apply(_ events: [EngineEvent]) {
        for event in events {
            switch event {
            case .postProposal(let isReminder):
                let minutes = Int(engine.workDuration(at: Date()) / engine.timing.secondsPerMinute)
                notifications.postProposal(isReminder: isReminder, workMinutes: minutes)
            case .withdrawProposal:
                notifications.withdrawProposal()
            case .postBreakOver:
                notifications.postBreakOver()
            }
        }
        updateIcon()
    }

    private func handle(_ action: ProposalAction) {
        let now = Date()
        NSLog("BreakTrigger: 選択 \(action)")
        switch action {
        case .takeBreak: apply(engine.takeBreak(now: now))
        case .snooze: apply(engine.snooze(now: now))
        case .skip: apply(engine.skip(now: now))
        }
        updateLiveMenuItems()
    }

    // MARK: - メニューバー

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let description: String
        switch (notifications.authorization, engine.phase) {
        case (.denied, _), (.notDetermined, _):
            symbol = "exclamationmark.triangle"
            description = "通知の許可が必要です"
        case (_, .due), (_, .proposed):
            symbol = "cup.and.saucer.fill"
            description = "休憩の目安に達しました"
        case (_, .snoozed):
            symbol = "bell.badge"
            description = "再通知を予約しています"
        case (_, .onBreak):
            symbol = "pause.circle"
            description = "休憩中"
        case (_, .screenOff):
            symbol = "moon"
            description = "画面が消えています"
        case (_, .working):
            symbol = "timer"
            description = "作業中"
        }
        if button.toolTip != description {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            button.imagePosition = .imageLeading
            button.toolTip = description
        }
        let title = statusBarTitle()
        if button.title != title {
            button.title = title
        }
    }

    /// アイコンの横に出す短い文字。アイコンだけでは状態が分かりにくいため、次に何が起きるかを書く
    private func statusBarTitle() -> String {
        switch notifications.authorization {
        case .denied, .notDetermined: return "通知オフ"
        case .allowed, .unknown: break
        }
        let now = Date()
        switch engine.phase {
        case .working:
            guard let start = engine.intervalStart else { return "" }
            let end = start.addingTimeInterval(TimeInterval(store.settings.workMinutes) * engine.timing.secondsPerMinute)
            return "あと\(minutesLeft(until: end, now: now))分"
        case .due, .proposed: return "休憩しよう"
        case .snoozed(let until): return "\(timeFormatter.string(from: until))に再通知"
        case .onBreak(let until): return "休憩中 あと\(minutesLeft(until: until, now: now))分"
        case .screenOff: return ""
        }
    }

    /// 残りの分。端数は切り上げ、0分にはしない
    private func minutesLeft(until end: Date, now: Date) -> Int {
        let seconds = end.timeIntervalSince(now)
        return max(1, Int((seconds / engine.timing.secondsPerMinute).rounded(.up)))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        notifications.refreshAuthorization()
        menu.removeAllItems()

        durationItem = disabledItem(durationText())
        menu.addItem(durationItem!)
        statusLineItem = disabledItem(statusText())
        menu.addItem(statusLineItem!)
        if let note = cancellationText() {
            menu.addItem(disabledItem(note))
        }

        if engine.phase == .proposed {
            menu.addItem(.separator())
            menu.addItem(actionItem("今休む", #selector(menuTakeBreak)))
            menu.addItem(actionItem("10分後にもう一度知らせる", #selector(menuSnooze)))
            menu.addItem(actionItem("今回はスキップ", #selector(menuSkip)))
        }

        switch notifications.authorization {
        case .denied:
            menu.addItem(.separator())
            menu.addItem(disabledItem("⚠︎ 通知が許可されていません"))
            menu.addItem(actionItem("通知の設定を開く…", #selector(openNotificationSettings)))
        case .notDetermined:
            menu.addItem(.separator())
            menu.addItem(disabledItem("⚠︎ 通知の許可が必要です"))
            menu.addItem(actionItem("通知を許可する…", #selector(requestNotificationPermission)))
        case .allowed, .unknown:
            break
        }

        menu.addItem(.separator())
        let settings = actionItem("設定…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(actionItem("Break Trigger を終了", #selector(quit)))
    }

    private func updateLiveMenuItems() {
        durationItem?.title = durationText()
        statusLineItem?.title = statusText()
    }

    private func durationText() -> String {
        switch engine.phase {
        case .onBreak: return "作業時間：休憩中"
        case .screenOff: return "作業時間：画面が消えています"
        default: break
        }
        let total = Int(engine.workDuration(at: Date()) / engine.timing.secondsPerMinute)
        let text = total >= 60 ? "\(total / 60)時間\(total % 60)分" : "\(total)分"
        return "作業時間：\(text)"
    }

    private func statusText() -> String {
        switch engine.phase {
        case .screenOff: return "画面がついたら計測を始めます"
        case .onBreak(let until): return "休憩の終わり：\(timeFormatter.string(from: until))"
        case .working: return "休憩の目安：\(store.settings.workMinutes)分"
        case .due: return "休憩の目安に達しました（操作の切れ目で通知します）"
        case .proposed: return "休憩の目安に達しました"
        case .snoozed(let until): return "再通知の予定：\(timeFormatter.string(from: until))"
        }
    }

    private func cancellationText() -> String? {
        switch engine.lastCancellation {
        case .screenOff: return "画面が消えたため、再通知を取り消しました"
        case .outsideSchedule: return "通知しない時間帯のため、再通知を取り消しました"
        case nil: return nil
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuTakeBreak() { handle(.takeBreak) }
    @objc private func menuSnooze() { handle(.snooze) }
    @objc private func menuSkip() { handle(.skip) }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openNotificationSettings() { notifications.openSystemSettings() }
    @objc private func requestNotificationPermission() { notifications.requestAuthorization() }
    @objc private func quit() { NSApp.terminate(nil) }
}
