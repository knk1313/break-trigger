import AppKit
import BreakTriggerCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    /// 月曜始まりで並べる（値は Calendar の weekday）
    private let weekdays: [(label: String, value: Int)] = [
        ("月", 2), ("火", 3), ("水", 4), ("木", 5), ("金", 6), ("土", 7), ("日", 1),
    ]

    var body: some View {
        Form {
            Section("休憩の提案") {
                Stepper(value: $store.settings.workMinutes, in: BreakSettings.workMinutesRange, step: 5) {
                    Text("休憩を挟まずに \(store.settings.workMinutes) 分作業したら提案する")
                }
                Text("「10分後」を選んだときは、10分後にもう一度通知します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知する曜日") {
                HStack {
                    ForEach(weekdays, id: \.value) { day in
                        Toggle(day.label, isOn: weekdayBinding(day.value))
                            .toggleStyle(.button)
                    }
                }
            }

            Section("通知する時間帯") {
                Toggle("時間帯を限定する", isOn: $store.settings.schedule.limitHours)
                DatePicker("開始", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    .disabled(!store.settings.schedule.limitHours)
                DatePicker("終了", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                    .disabled(!store.settings.schedule.limitHours)
                Text("終了が開始より前のときは、日をまたぐ時間帯として扱います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("設定はこのMacの中だけに保存します。キーボードとマウスは操作があったかどうかだけを使い、入力した内容は読み取りません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.contentSize.width)
        .frame(minHeight: 300, maxHeight: .infinity)
    }

    private func weekdayBinding(_ value: Int) -> Binding<Bool> {
        Binding(
            get: { store.settings.schedule.weekdays.contains(value) },
            set: { isOn in
                if isOn {
                    store.settings.schedule.weekdays.insert(value)
                } else {
                    store.settings.schedule.weekdays.remove(value)
                }
            }
        )
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<NotificationSchedule, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(
            get: {
                let midnight = calendar.startOfDay(for: Date())
                return midnight.addingTimeInterval(TimeInterval(store.settings.schedule[keyPath: keyPath] * 60))
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                store.settings.schedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

final class SettingsWindowController {
    static let contentSize = NSSize(width: 440, height: 530)
    private var window: NSWindow?
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store))
            // SwiftUI に大きさを決めさせると、表示の後に上へ伸びて画面の外にはみ出すため、先に大きさを決める
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Break Trigger の設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        guard let window else { return }
        if !window.isVisible {
            placeOnScreen(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// メニューバーのある画面の中央に、画面に収まる大きさで置く。
    private func placeOnScreen(_ window: NSWindow) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let titleBar = window.frameRect(forContentRect: .zero).height
        var size = Self.contentSize
        size.height = min(size.height, visible.height - titleBar - 40)
        window.setContentSize(size)
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
        if ProcessInfo.processInfo.environment["BREAK_TRIGGER_OPEN_SETTINGS"] == "1" {
            NSLog("BreakTrigger: 設定のウインドウ \(NSStringFromRect(window.frame)) 画面 \(NSStringFromRect(visible))")
        }
    }
}
