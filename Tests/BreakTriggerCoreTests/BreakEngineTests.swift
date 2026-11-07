import Foundation
import Testing
@testable import BreakTriggerCore

/// 1秒ごとに時刻を進め、操作の有無をまねてエンジンに渡す。
final class Simulator {
    let engine: BreakEngine
    private(set) var now: Date
    private var lastInput: Date
    private(set) var events: [(at: Date, event: EngineEvent)] = []

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-11-09（月）の `hour` 時ちょうどから始める
    init(settings: BreakSettings = BreakSettings(), hour: Int = 10, minute: Int = 0) {
        let start = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: hour, minute: minute))!
        now = start
        lastInput = start.addingTimeInterval(-3600)
        engine = BreakEngine(settings: settings, calendar: Self.calendar, now: start)
    }

    /// `seconds` 秒のあいだ、毎秒操作する
    func work(_ seconds: Int) {
        for _ in 0..<seconds {
            now.addTimeInterval(1)
            lastInput = now
            record(engine.tick(now: now, idle: 0))
        }
    }

    /// `seconds` 秒のあいだ、操作しない
    func pause(_ seconds: Int) {
        for _ in 0..<seconds {
            now.addTimeInterval(1)
            record(engine.tick(now: now, idle: now.timeIntervalSince(lastInput)))
        }
    }

    func screenOff() { record(engine.handleScreenOff(now: now)) }
    func screenOn(after seconds: Int) {
        now.addTimeInterval(TimeInterval(seconds))
        record(engine.handleScreenOn(now: now))
    }
    func takeBreak() { record(engine.takeBreak(now: now)) }
    func snooze() { record(engine.snooze(now: now)) }
    func skip() { record(engine.skip(now: now)) }

    var proposals: [(at: Date, isReminder: Bool)] {
        events.compactMap { item in
            if case .postProposal(let isReminder) = item.event { return (item.at, isReminder) }
            return nil
        }
    }

    var breakOvers: [Date] {
        events.compactMap { $0.event == .postBreakOver ? $0.at : nil }
    }

    func clearEvents() { events.removeAll() }

    private func record(_ new: [EngineEvent]) {
        events += new.map { (now, $0) }
    }
}

private let minute = 60

@Suite("作業時間の計測と初回の通知")
struct FirstProposalTests {
    @Test("操作が続く間は通知せず、数秒途切れたところで1回だけ通知する")
    func waitsForPause() {
        let sim = Simulator()
        sim.work(50 * minute + 120)  // 50分を超えても操作が続いている
        #expect(sim.proposals.isEmpty)
        #expect(sim.engine.phase == .due)

        sim.pause(2)
        #expect(sim.proposals.isEmpty)  // 2秒では切れ目とみなさない
        sim.pause(1)
        #expect(sim.proposals.count == 1)
        #expect(sim.proposals[0].isReminder == false)
        #expect(sim.engine.phase == .proposed)

        // 選択を待つ間は、操作の切れ目が何度あっても重ねて通知しない
        for _ in 0..<5 {
            sim.work(30)
            sim.pause(10)
        }
        #expect(sim.proposals.count == 1)
    }

    @Test("設定時間より前の切れ目では通知しない")
    func noProposalBeforeInterval() {
        let sim = Simulator()
        for _ in 0..<48 {
            sim.work(50)
            sim.pause(10)
        }
        #expect(sim.proposals.isEmpty)
        #expect(sim.engine.phase == .working)
    }

    @Test("操作がなくても、画面がついている間は作業時間に含める")
    func idleCountsAsWork() {
        let sim = Simulator()
        sim.work(10 * minute)
        sim.pause(40 * minute)  // 長く手を止めても、画面がついていればリセットしない
        #expect(sim.engine.phase == .proposed)
        #expect(sim.proposals.count == 1)
    }

    @Test("画面が消えたら作業時間をリセットし、画面がついた時刻から計測を再開する")
    func screenOffResets() {
        let sim = Simulator()
        sim.work(40 * minute)
        sim.screenOff()
        #expect(sim.engine.phase == .screenOff)
        #expect(sim.engine.workDuration(at: sim.now) == 0)

        sim.pause(10 * minute)  // 画面が消えている間は計測しない
        #expect(sim.engine.workStart == nil)

        sim.screenOn(after: 0)
        #expect(sim.engine.phase == .working)
        #expect(sim.engine.workStart == sim.now)
        sim.work(45 * minute)
        sim.pause(3)
        #expect(sim.proposals.isEmpty)  // リセット後はまだ45分
        sim.work(5 * minute)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
    }

    @Test("初回の通知待ちも、画面が消えたらリセットする")
    func screenOffResetsDue() {
        let sim = Simulator()
        sim.work(55 * minute)
        #expect(sim.engine.phase == .due)
        sim.screenOff()
        sim.screenOn(after: 60)
        sim.work(1)
        sim.pause(3)
        #expect(sim.proposals.isEmpty)
    }

    @Test("画面が消えた状態で起動したら、画面がつくまで計測しない")
    func startsWithScreenOff() {
        let start = Date(timeIntervalSince1970: 0)
        let engine = BreakEngine(settings: BreakSettings(), now: start, isScreenOn: false)
        #expect(engine.phase == .screenOff)
        #expect(engine.tick(now: start.addingTimeInterval(3600), idle: 3600).isEmpty)
        _ = engine.handleScreenOn(now: start.addingTimeInterval(3600))
        #expect(engine.workStart == start.addingTimeInterval(3600))
    }

    @Test("設定した作業時間で提案する")
    func customInterval() {
        let sim = Simulator(settings: BreakSettings(workMinutes: 25))
        sim.work(25 * minute)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
    }
}

@Suite("通知の選択肢")
struct ActionTests {
    private func proposed(_ settings: BreakSettings = BreakSettings(), hour: Int = 10, minute startMinute: Int = 0) -> Simulator {
        let sim = Simulator(settings: settings, hour: hour, minute: startMinute)
        sim.work(50 * minute)
        sim.pause(3)
        #expect(sim.engine.phase == .proposed)
        sim.clearEvents()
        return sim
    }

    @Test("今休む：10分後に休憩の終わりを知らせ、その時刻から作業時間を数え直す")
    func takeBreak() {
        let sim = proposed()
        let selectedAt = sim.now
        sim.takeBreak()
        #expect(sim.events.map(\.event) == [.withdrawProposal])
        #expect(sim.engine.breakUntil == selectedAt.addingTimeInterval(600))
        #expect(sim.engine.workStart == nil)

        sim.work(10 * minute - 1)  // 休憩中にPCを使っていても、休憩の扱いは変わらない
        #expect(sim.breakOvers.isEmpty)
        sim.work(1)
        #expect(sim.breakOvers == [selectedAt.addingTimeInterval(600)])
        #expect(sim.engine.phase == .working)
        #expect(sim.engine.workStart == sim.now)

        sim.work(50 * minute)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
        #expect(sim.breakOvers.count == 1)
    }

    @Test("休憩中に画面が消えても休憩の終わりを知らせ、計測は画面がついてから始める")
    func breakWithScreenOff() {
        let sim = proposed()
        sim.takeBreak()
        sim.screenOff()
        #expect(sim.engine.breakUntil != nil)
        sim.pause(10 * minute)
        #expect(sim.breakOvers.count == 1)
        #expect(sim.engine.phase == .screenOff)
        sim.pause(5 * minute)
        sim.screenOn(after: 0)
        #expect(sim.engine.workStart == sim.now)
    }

    @Test("休憩中に画面が消えてまたついても、休憩はそのまま続く")
    func breakSurvivesScreenToggle() {
        let sim = proposed()
        sim.takeBreak()
        sim.pause(2 * minute)
        sim.screenOff()
        sim.screenOn(after: 3 * minute)
        #expect(sim.engine.breakUntil != nil)
        sim.pause(5 * minute)
        #expect(sim.breakOvers.count == 1)
        #expect(sim.engine.phase == .working)
    }

    @Test("休憩の終わりは、通知しない時間帯でも知らせる")
    func breakOverIgnoresSchedule() {
        let schedule = NotificationSchedule(limitHours: true, startMinute: 9 * 60, endMinute: 11 * 60)
        let sim = proposed(BreakSettings(schedule: schedule), hour: 10, minute: 0)
        sim.takeBreak()  // 10:50 に休憩、11:00 は対象外
        sim.pause(10 * minute)
        #expect(sim.breakOvers.count == 1)
    }

    @Test("10分後：操作が続いていても、選択からちょうど10分後に再通知する")
    func snoozeFiresAfterTenMinutes() {
        let sim = proposed()
        let selectedAt = sim.now
        sim.snooze()
        #expect(sim.engine.snoozeUntil == selectedAt.addingTimeInterval(600))

        sim.work(10 * minute - 1)
        #expect(sim.proposals.isEmpty)
        sim.work(1)
        #expect(sim.proposals.count == 1)
        #expect(sim.proposals[0].isReminder)
        #expect(sim.proposals[0].at == selectedAt.addingTimeInterval(600))
    }

    @Test("再通知でも「10分後」を選べ、何度でも繰り返せる")
    func snoozeRepeatedly() {
        let sim = proposed()
        for round in 1...3 {
            sim.snooze()
            sim.work(10 * minute)
            #expect(sim.proposals.count == round)
            #expect(sim.engine.phase == .proposed)
        }
        sim.skip()
        #expect(sim.engine.phase == .working)
    }

    @Test("予約中は、操作の切れ目があっても初回の通知を重ねて出さない")
    func noDuplicateWhileSnoozed() {
        let sim = proposed()
        sim.snooze()
        for _ in 0..<9 {
            sim.work(50)
            sim.pause(10)  // 作業時間は50分を超えているが、初回の通知は出ない
        }
        #expect(sim.proposals.isEmpty)
        sim.work(60)
        #expect(sim.proposals.count == 1)
        #expect(sim.proposals[0].isReminder)
        // 再通知の後も、10分経つまでは重ねて通知しない
        sim.pause(4 * minute)
        sim.work(6 * minute - 10)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
    }

    @Test("選ばれないまま放置されたら、10分ごとに再通知する")
    func remindsWhenUnanswered() {
        let sim = proposed()
        let proposedAt = sim.now
        sim.work(10 * minute - 1)
        #expect(sim.proposals.isEmpty)
        sim.work(1)
        #expect(sim.proposals.count == 1)
        #expect(sim.proposals[0].isReminder)
        #expect(sim.proposals[0].at == proposedAt.addingTimeInterval(600))
        #expect(sim.engine.phase == .proposed)

        sim.pause(10 * minute)
        #expect(sim.proposals.count == 2)

        // 選べば、それ以降は放置の再通知を出さない
        sim.takeBreak()
        sim.pause(9 * minute)
        #expect(sim.proposals.count == 2)
    }

    @Test("放置の再通知の時刻が通知しない時間帯なら、提案を取り下げて次の間隔を数える")
    func unansweredOutsideSchedule() {
        let schedule = NotificationSchedule(limitHours: true, startMinute: 9 * 60, endMinute: 11 * 60)
        let sim = proposed(BreakSettings(schedule: schedule), hour: 10, minute: 5)  // 10:55 に提案、11:05 は対象外
        sim.pause(10 * minute)
        #expect(sim.proposals.isEmpty)
        #expect(sim.events.map(\.event) == [.withdrawProposal])
        #expect(sim.engine.phase == .working)
    }

    @Test("今回はスキップ：その時点から次の作業間隔を数える")
    func skip() {
        let sim = proposed()
        let skippedAt = sim.now
        sim.skip()
        #expect(sim.events.map(\.event) == [.withdrawProposal])
        #expect(sim.engine.intervalStart == skippedAt)
        // 作業時間の表示は最後の休憩からのまま続く
        #expect(sim.engine.workDuration(at: sim.now) >= 50 * 60)

        sim.work(49 * minute)
        sim.pause(3)
        #expect(sim.proposals.isEmpty)
        sim.work(1 * minute)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
        #expect(sim.proposals[0].isReminder == false)
    }

    @Test("提案中でないときの選択は無視する")
    func ignoresStaleActions() {
        let sim = Simulator()
        sim.work(10 * minute)
        sim.snooze()
        sim.skip()
        sim.takeBreak()
        #expect(sim.engine.phase == .working)
        #expect(sim.events.isEmpty)
    }
}

@Suite("再通知の予約の取り消し")
struct SnoozeCancellationTests {
    private func snoozed(_ settings: BreakSettings = BreakSettings(), hour: Int = 10, minute startMinute: Int = 0) -> Simulator {
        let sim = Simulator(settings: settings, hour: hour, minute: startMinute)
        sim.work(50 * minute)
        sim.pause(3)
        sim.snooze()
        #expect(sim.engine.snoozeUntil != nil)
        sim.clearEvents()
        return sim
    }

    @Test("長く手を止めても取り消さない")
    func notCancelledByIdle() {
        let sim = snoozed()
        sim.pause(10 * minute)
        #expect(sim.proposals.count == 1)
    }

    @Test("画面が消えたら取り消し、画面がついたら計測を再開する")
    func cancelledByScreenOff() {
        let sim = snoozed()
        sim.work(2 * minute)
        sim.screenOff()
        #expect(sim.events.map(\.event) == [.withdrawProposal])
        #expect(sim.engine.phase == .screenOff)
        #expect(sim.engine.lastCancellation == .screenOff)
        sim.screenOn(after: 30)
        #expect(sim.engine.workStart == sim.now)
        sim.work(10 * minute)
        #expect(sim.proposals.isEmpty)
    }

    @Test("提案中に画面が消えたら、通知を取り下げる")
    func proposalWithdrawnByScreenOff() {
        let sim = Simulator()
        sim.work(50 * minute)
        sim.pause(3)
        sim.clearEvents()
        sim.screenOff()
        #expect(sim.events.map(\.event) == [.withdrawProposal])
        #expect(sim.engine.lastCancellation == nil)
    }

    @Test("再通知の時刻が通知する時間帯の外なら、選択の時点で取り消す")
    func cancelledWhenFireTimeOutsideHours() {
        // 9:00〜18:00 のみ通知。17:00 から作業を始め、17:50 に提案、18:00 は対象外
        let schedule = NotificationSchedule(limitHours: true, startMinute: 9 * 60, endMinute: 18 * 60)
        let sim = Simulator(settings: BreakSettings(schedule: schedule), hour: 17, minute: 0)
        sim.work(50 * minute)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
        sim.clearEvents()

        sim.snooze()
        #expect(sim.engine.snoozeUntil == nil)
        #expect(sim.engine.lastCancellation == .outsideSchedule)
        #expect(sim.events.map(\.event) == [.withdrawProposal])
        sim.work(60 * minute)
        sim.pause(3)
        #expect(sim.proposals.isEmpty)
    }

    @Test("再通知の時刻が通知しない曜日なら取り消す")
    func cancelledWhenFireTimeOnExcludedWeekday() {
        // 月曜 23:00 から作業。23:50 の提案で「10分後」→ 火曜 0:00 は対象外
        let schedule = NotificationSchedule(weekdays: [2])
        let sim = Simulator(settings: BreakSettings(schedule: schedule), hour: 23, minute: 0)
        sim.work(50 * minute)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
        sim.snooze()
        #expect(sim.engine.snoozeUntil == nil)
        #expect(sim.engine.lastCancellation == .outsideSchedule)
    }

    @Test("予約の後に設定を変え、再通知の時刻が対象外になったら、その時刻に取り消す")
    func cancelledAtFireTimeAfterSettingsChange() {
        let sim = snoozed()
        sim.engine.settings.schedule = NotificationSchedule(limitHours: true, startMinute: 9 * 60, endMinute: 10 * 60 + 55)
        sim.work(10 * minute)
        #expect(sim.proposals.isEmpty)
        #expect(sim.engine.phase == .working)
        #expect(sim.engine.lastCancellation == .outsideSchedule)
    }
}

@Suite("通知する曜日と時間帯")
struct ScheduleTests {
    private let calendar = Simulator.calendar

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test("対象外の時間帯は、提案の時間に達しても通知せず、対象になってから通知する")
    func waitsUntilHoursStart() {
        let schedule = NotificationSchedule(limitHours: true, startMinute: 9 * 60, endMinute: 18 * 60)
        let sim = Simulator(settings: BreakSettings(schedule: schedule), hour: 8, minute: 0)
        sim.work(55 * minute)
        sim.pause(3)
        #expect(sim.proposals.isEmpty)  // 8:55
        #expect(sim.engine.phase == .working)
        sim.work(5 * minute)  // 9:00 を過ぎる
        #expect(sim.engine.phase == .due)
        sim.pause(3)
        #expect(sim.proposals.count == 1)
    }

    @Test("時間帯と曜日の判定")
    func allows() {
        let day = NotificationSchedule(weekdays: Set(2...6), limitHours: true, startMinute: 9 * 60, endMinute: 18 * 60)
        #expect(day.allows(date(day: 9, hour: 9), calendar: calendar))           // 月 9:00
        #expect(!day.allows(date(day: 9, hour: 8, minute: 59), calendar: calendar))
        #expect(!day.allows(date(day: 9, hour: 18), calendar: calendar))         // 終了は含まない
        #expect(!day.allows(date(day: 8, hour: 12), calendar: calendar))         // 日曜

        let night = NotificationSchedule(limitHours: true, startMinute: 22 * 60, endMinute: 2 * 60)
        #expect(night.allows(date(day: 9, hour: 23), calendar: calendar))
        #expect(night.allows(date(day: 10, hour: 1, minute: 59), calendar: calendar))
        #expect(!night.allows(date(day: 10, hour: 2), calendar: calendar))

        let allDay = NotificationSchedule(limitHours: false)
        #expect(allDay.allows(date(day: 9, hour: 3), calendar: calendar))
    }
}
