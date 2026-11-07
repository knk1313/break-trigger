import Foundation

/// 休憩の提案の状態。
public enum Phase: Equatable, Sendable {
    /// 画面が消えている。画面がついたら計測を始める
    case screenOff
    /// 作業中。提案の時間にまだ達していない
    case working
    /// 提案の時間に達し、操作の切れ目を待っている
    case due
    /// 通知を出し、選択を待っている。選ばれないまま「10分後」の長さが経つと、もう一度通知する
    case proposed
    /// 「10分後」が選ばれ、再通知を予約している
    case snoozed(until: Date)
    /// 「今休む」が選ばれ、休憩の終わりを待っている
    case onBreak(until: Date)
}

/// エンジンが通知の層に求める操作。
public enum EngineEvent: Equatable, Sendable {
    case postProposal(isReminder: Bool)
    case withdrawProposal
    /// 休憩の終わりを知らせる
    case postBreakOver
}

/// 再通知の予約を取り消した理由。メニューに表示する。
public enum SnoozeCancellation: Equatable, Sendable {
    case screenOff
    case outsideSchedule
}

public struct EngineTiming: Sendable {
    /// 提案の時間に達した後、これ以上の無操作を「操作の切れ目」とみなす
    public var pauseIdle: TimeInterval
    /// 「10分後」の長さ
    public var snooze: TimeInterval
    /// 「今休む」を選んだときの休憩の長さ
    public var breakLength: TimeInterval
    /// 設定の1分を何秒として扱うか
    public var secondsPerMinute: TimeInterval

    public init(pauseIdle: TimeInterval = 3, snooze: TimeInterval = 600, breakLength: TimeInterval = 600, secondsPerMinute: TimeInterval = 60) {
        self.pauseIdle = pauseIdle
        self.snooze = snooze
        self.breakLength = breakLength
        self.secondsPerMinute = secondsPerMinute
    }

    /// 動作確認用に、操作の切れ目以外の時間を `scale` 分の1に縮める。
    public static func scaled(by scale: Double) -> EngineTiming {
        let base = EngineTiming()
        return EngineTiming(
            pauseIdle: base.pauseIdle,
            snooze: base.snooze / scale,
            breakLength: base.breakLength / scale,
            secondsPerMinute: base.secondsPerMinute / scale
        )
    }
}

/// 作業時間の計測と、休憩の提案・再通知・休憩の終わりの判定。
/// 画面がついている間を作業時間として数える。
/// 時刻、無操作の秒数、画面の状態を外から受け取るため、OSに依存せずに検査できる。
public final class BreakEngine {
    public var settings: BreakSettings
    public let timing: EngineTiming
    public var calendar: Calendar

    public private(set) var phase: Phase
    /// 作業時間を数え始めた時刻（画面がついた時刻か、休憩が終わった時刻）
    public private(set) var workStart: Date?
    /// 次の提案までの時間を数え始めた時刻。「今回はスキップ」で更新する
    public private(set) var intervalStart: Date?
    /// 直近に再通知の予約を取り消した理由
    public private(set) var lastCancellation: SnoozeCancellation?
    /// 画面がついているか
    public private(set) var isScreenOn: Bool
    /// 直近に提案の通知を出した時刻。選ばれないまま放置されたときの再通知に使う
    private var proposedAt: Date?

    /// 画面がついた状態で始め、`now` から作業時間を数える。
    public init(settings: BreakSettings, timing: EngineTiming = EngineTiming(), calendar: Calendar = .current, now: Date, isScreenOn: Bool = true) {
        self.settings = settings
        self.timing = timing
        self.calendar = calendar
        self.isScreenOn = isScreenOn
        self.phase = .screenOff
        if isScreenOn {
            startWork(at: now)
        }
    }

    public var snoozeUntil: Date? {
        if case .snoozed(let until) = phase { return until }
        return nil
    }

    public var breakUntil: Date? {
        if case .onBreak(let until) = phase { return until }
        return nil
    }

    /// 作業時間を数え始めてからの時間
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
        switch phase {
        case .screenOff:
            return []
        case .proposed:
            // 通知はバナーだと数秒で消えるため、選ばれないまま放置されたら同じ間隔でもう一度知らせる
            guard let proposedAt, now.timeIntervalSince(proposedAt) >= timing.snooze else { return [] }
            guard allows(now) else {
                restartInterval(at: now)
                return [.withdrawProposal]
            }
            self.proposedAt = now
            return [.postProposal(isReminder: true)]
        case .onBreak(let until):
            guard now >= until else { return [] }
            // 休憩の終わりは、曜日や時間帯にかかわらず知らせる
            if isScreenOn {
                startWork(at: now)
            } else {
                endWork()
            }
            return [.postBreakOver]
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
            proposedAt = now
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
        proposedAt = now
        lastCancellation = nil
        return [.postProposal(isReminder: false)]
    }

    // MARK: - 画面

    /// 画面が消えた（ディスプレイのスリープ、画面のロック、Macのスリープ）。作業時間をリセットする。
    /// 休憩中は、休憩の終わりの予定をそのまま残す。
    public func handleScreenOff(now: Date) -> [EngineEvent] {
        isScreenOn = false
        if case .onBreak = phase { return [] }
        let wasSnoozed = snoozeUntil != nil
        let hadProposal = phase == .proposed || wasSnoozed
        if wasSnoozed {
            lastCancellation = .screenOff
        }
        endWork()
        return hadProposal ? [.withdrawProposal] : []
    }

    /// 画面がついた。休憩中でなければ、この時刻から作業時間を数える。
    public func handleScreenOn(now: Date) -> [EngineEvent] {
        isScreenOn = true
        if phase == .screenOff {
            startWork(at: now)
        }
        return []
    }

    // MARK: - 通知の選択肢

    /// 今休む：休憩の長さの後に、休憩の終わりを知らせる
    public func takeBreak(now: Date) -> [EngineEvent] {
        guard phase == .proposed else { return [] }
        lastCancellation = nil
        phase = .onBreak(until: now.addingTimeInterval(timing.breakLength))
        workStart = nil
        intervalStart = nil
        return [.withdrawProposal]
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

    private func startWork(at now: Date) {
        phase = .working
        workStart = now
        intervalStart = now
    }

    private func restartInterval(at now: Date) {
        phase = .working
        intervalStart = now
    }

    private func endWork() {
        phase = .screenOff
        workStart = nil
        intervalStart = nil
    }
}
