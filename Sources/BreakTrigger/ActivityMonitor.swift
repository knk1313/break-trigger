import CoreGraphics
import Foundation

/// キーボードとマウスの操作の有無を調べる。
/// 最後の入力からの秒数だけを読み、入力の内容は読まない。
/// この API は「入力監視」や「アクセシビリティ」の許可を必要としない。
enum ActivityMonitor {
    /// kCGAnyInputEventType（C のマクロで、Swift には取り込まれない）
    private static let anyInputEventType = CGEventType(rawValue: ~0)!

    static func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
    }
}
