import BreakTriggerCore
import Foundation

/// 設定を UserDefaults（このMacの中）に保存する。
final class SettingsStore: ObservableObject {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    @Published var settings: BreakSettings {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(BreakSettings.self, from: data) {
            settings = saved
        } else {
            settings = BreakSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
