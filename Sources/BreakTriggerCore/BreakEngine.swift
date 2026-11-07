import Foundation

/// 休憩の提案の状態。
public enum Phase: Equatable, Sendable {
    /// 休憩中。次の操作から計測を始める
    case resting
    /// 作業中。提案の時間にまだ達していない
    case working
    /// 提案の時間に達し、操作の切れ目を待っている
    case due
    /// 通知を出し、選択を待っている
    case proposed
    /// 「10分後」が選ばれ、再通知を予約している
    case snoozed(until: Date)
}

/// エンジンが通知の層に求める操作。
public enum EngineEvent: Equatable, Sendable {
    case postProposal(isReminder: Bool)
    case withdrawProposal
}

/// 再通知の予約を取り消した理由。メニューに表示する。
public enum SnoozeCancellation: Equatable, Sendable {
    case breakTaken
    case sleep
    case outsideSchedule
}

public struct EngineTiming: Sendable {
    /// これ以上の無操作を休憩とみなす
    public var breakIdle: TimeInterval
    /// 提案の時間に達した後、これ以上の無操作を「操作の切れ目」とみなす
    public var pauseIdle: TimeInterval
    /// 「10分後」の長さ
    public var snooze: TimeInterval
    /// 設定の1分を何秒として扱うか
    public var secondsPerMinute: TimeInterval

    public init(breakIdle: TimeInterval = 300, pauseIdle: TimeInterval = 3, snooze: TimeInterval = 600, secondsPerMinute: TimeInterval = 60) {
        self.breakIdle = breakIdle
        self.pauseIdle = pauseIdle
        self.snooze = snooze
        self.secondsPerMinute = secondsPerMinute
    }

    /// 動作確認用に、操作の切れ目以外の時間を `scale` 分の1に縮める。
    public static func scaled(by scale: Double) -> EngineTiming {
        let base = EngineTiming()
        return EngineTiming(
            breakIdle: base.breakIdle / scale,
            pauseIdle: base.pauseIdle,
            snooze: base.snooze / scale,
            secondsPerMinute: base.secondsPerMinute / scale
        )
    }
}

/// 作業時間の計測と、休憩の提案・再通知の判定。
/// 時刻と無操作の秒数を外から受け取るため、OSに依存せずに検査できる。
public final class BreakEngine {
    public var settings: BreakSettings
    public let timing: EngineTiming
    public var calendar: Calendar

    public private(set) var phase: Phase = .resting
    /// 最後の休憩の後、最初に操作した時刻
    public private(set) var workStart: Date?
    /// 次の提案までの時間を数え始めた時刻。「今回はスキップ」で更新する
    public private(set) var intervalStart: Date?
    /// 直近に再通知の予約を取り消した理由
    public private(set) var lastCancellation: SnoozeCancellation?
    /// この時刻より後の操作で、計測を再開する
    private var restingSince: Date

    public init(settings: BreakSettings, timing: EngineTiming = EngineTiming(), calendar: Calendar = .current, now: Date) {
        self.settings = settings
        self.timing = timing
        self.calendar = calendar
        self.restingSince = now
    }

    public var snoozeUntil: Date? {
        if case .snoozed(let until) = phase { return until }
        return nil
    }

    /// 最後の休憩からの作業時間
    public func workDuration(at now: Date) -> TimeInterval {
        guard let workStart else { return 0 }
        return max(0, now.timeIntervalSince(workStart))
    }

    private var proposalInterval: TimeInterval {
        TimeInterval(settings.workMinutes) * timing.secondsPerMinute
    }

    private func allows(_ date: Date) -> Bool {
        settings.schedule.allows(date, calendar: calendar)
    }

    // MARK: - 時間の経過

    /// 1秒ごとに呼ぶ。`idle` は最後の操作からの秒数。
    public func tick(now: Date, idle: TimeInterval) -> [EngineEvent] {
        if phase == .resting {
            let lastInput = now.addingTimeInterval(-idle)
            guard lastInput > restingSince, idle < timing.breakIdle else { return [] }
            phase = .working
            workStart = lastInput
            intervalStart = lastInput
        }

        if idle >= timing.breakIdle {
            return reset(at: now, reason: .breakTaken)
        }

        switch phase {
        case .resting, .proposed:
            return []
        case .working:
            guard let intervalStart,
                  now.timeIntervalSince(intervalStart) >= proposalInterval,
                  allows(now) else { return [] }
            phase = .due
            return tickDue(now: now, idle: idle)
        case .due:
            return tickDue(now: now, idle: idle)
        case .snoozed(let until):
            // 再通知は操作の切れ目を待たない
            guard now >= until else { return [] }
            guard allows(now) else {
                restartInterval(at: now)
                lastCancellation = .outsideSchedule
                return []
            }
            phase = .proposed
            return [.postProposal(isReminder: true)]
        }
    }

    private func tickDue(now: Date, idle: TimeInterval) -> [EngineEvent] {
        guard allows(now) else {
            // 対象の時間帯を抜けたら、次に対象になるまで待つ
            phase = .working
            return []
        }
        guard idle >= timing.pauseIdle else { return [] }
        phase = .proposed
        lastCancellation = nil
        return [.postProposal(isReminder: false)]
    }

    // MARK: - スリープ

    public func handleSleep(now: Date) -> [EngineEvent] {
        reset(at: now, reason: .sleep)
    }

    /// スリープの通知を受け取れなかった場合に備え、復帰でも区切る。
    public func handleWake(now: Date) -> [EngineEvent] {
        guard phase != .resting else {
            restingSince = now
            return []
        }
        return reset(at: now, reason: .sleep)
    }

    // MARK: - 通知の選択肢

    /// 今休む
    public func takeBreak(now: Date) -> [EngineEvent] {
        guard phase == .proposed else { return [] }
        lastCancellation = nil
        return reset(at: now, reason: nil)
    }

    /// 10分後
    public func snooze(now: Date) -> [EngineEvent] {
        guard phase == .proposed else { return [] }
        let until = now.addingTimeInterval(timing.snooze)
        if allows(until) {
            phase = .snoozed(until: until)
            lastCancellation = nil
        } else {
            restartInterval(at: now)
            lastCancellation = .outsideSchedule
        }
        return [.withdrawProposal]
    }

    /// 今回はスキップ
    public func skip(now: Date) -> [EngineEvent] {
        guard phase == .proposed else { return [] }
        restartInterval(at: now)
        lastCancellation = nil
        return [.withdrawProposal]
    }

    // MARK: -

    private func restartInterval(at now: Date) {
        phase = .working
        intervalStart = now
    }

    private func reset(at now: Date, reason: SnoozeCancellation?) -> [EngineEvent] {
        let wasSnoozed = snoozeUntil != nil
        let hadProposal = phase == .proposed || wasSnoozed
        phase = .resting
        workStart = nil
        intervalStart = nil
        restingSince = now
        if wasSnoozed, let reason {
            lastCancellation = reason
        }
        return hadProposal ? [.withdrawProposal] : []
    }
}
