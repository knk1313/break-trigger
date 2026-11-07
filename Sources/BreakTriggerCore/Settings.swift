import Foundation

/// 通知してよい曜日と時間帯。
public struct NotificationSchedule: Codable, Equatable, Sendable {
    /// 通知する曜日。`Calendar` の weekday（1＝日曜、7＝土曜）で持つ
    public var weekdays: Set<Int>
    /// false のときは、選んだ曜日なら終日通知する
    public var limitHours: Bool
    /// 0時からの分。開始を含み、終了を含まない
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int> = Set(1...7), limitHours: Bool = false, startMinute: Int = 9 * 60, endMinute: Int = 18 * 60) {
        self.weekdays = weekdays
        self.limitHours = limitHours
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// `date` が通知の対象かどうか。終了が開始より前なら、日をまたぐ時間帯として扱う。
    /// 曜日は `date` 自身の曜日で判定する。
    public func allows(_ date: Date, calendar: Calendar) -> Bool {
        guard weekdays.contains(calendar.component(.weekday, from: date)) else { return false }
        guard limitHours, startMinute != endMinute else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }
}

public struct BreakSettings: Codable, Equatable, Sendable {
    public static let workMinutesRange = 5...240

    /// 休憩を提案するまでの作業時間（分）
    public var workMinutes: Int
    public var schedule: NotificationSchedule

    public init(workMinutes: Int = 50, schedule: NotificationSchedule = NotificationSchedule()) {
        self.workMinutes = workMinutes
        self.schedule = schedule
    }
}
