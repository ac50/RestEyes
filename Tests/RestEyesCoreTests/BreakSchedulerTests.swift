import XCTest
@testable import RestEyesCore

final class BreakSchedulerTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func after(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func makeConfig(work: Double = 1, rest: Double = 1, warn: Int = 10,
                            unlock: UnlockAfter = .seconds(60)) -> Config {
        var c = Config()
        c.workMinutes = work      // 1 分钟 = 60 秒,便于推算
        c.restMinutes = rest
        c.warnSeconds = warn
        c.unlockAfter = unlock
        return c
    }

    private func makeScheduler(_ config: Config) -> (BreakScheduler, () -> [Phase], () -> [TickInfo]) {
        let s = BreakScheduler(config: config, now: t0)
        var phases: [Phase] = []
        var infos: [TickInfo] = []
        s.onPhaseChange = { phases.append($0) }
        s.onTick = { infos.append($0) }
        return (s, { phases }, { infos })
    }

    // 初始即 working,不触发 onPhaseChange
    func testInitStartsWorking() {
        let (s, phases, _) = makeScheduler(makeConfig())
        XCTAssertEqual(s.phase, .working)
        XCTAssertTrue(phases().isEmpty)
        XCTAssertFalse(s.skipNextArmed)
    }

    // 完整周期:working → warning → resting → working
    func testFullCycle() {
        let (s, phases, _) = makeScheduler(makeConfig())
        s.tick(now: after(59))
        XCTAssertEqual(s.phase, .working)
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
        s.tick(now: after(70))    // 预警 10 秒到点
        XCTAssertEqual(s.phase, .resting)
        s.tick(now: after(130))   // 休息 60 秒到点
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(phases(), [.warning, .resting, .working])
    }

    // warn = 0 直接进 resting
    func testWarnZeroSkipsWarning() {
        let (s, phases, _) = makeScheduler(makeConfig(warn: 0))
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(phases(), [.resting])
    }

    // skipNext:消费一次后清除,下个周期正常休息
    func testSkipNextSkipsOneBreakThenClears() {
        let (s, phases, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        XCTAssertTrue(s.skipNextArmed)
        s.tick(now: after(60))            // 到点:跳过,重开工作
        XCTAssertEqual(s.phase, .working)
        XCTAssertFalse(s.skipNextArmed)
        s.tick(now: after(120))           // 第二个周期到点:正常预警
        XCTAssertEqual(s.phase, .warning)
        XCTAssertEqual(phases(), [.warning])
    }

    // 再点一次取消
    func testToggleSkipNextTwiceCancels() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        s.toggleSkipNext()
        XCTAssertFalse(s.skipNextArmed)
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
    }

    // 预警中按下 skipNext:预警到点后跳过休息
    func testSkipNextDuringWarning() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
        s.toggleSkipNext()
        s.tick(now: after(70))
        XCTAssertEqual(s.phase, .working)
        XCTAssertFalse(s.skipNextArmed)
    }

    // breakNow:立即休息,清除 skipNext
    func testBreakNowEntersRestingAndClearsSkip() {
        let (s, phases, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        s.breakNow(now: after(10))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(phases(), [.resting])
        s.tick(now: after(70))            // 休息 60 秒后回工作
        XCTAssertEqual(s.phase, .working)
    }

    // unlock 提前结束休息并重开工作
    func testUnlockEndsRestEarly() {
        let (s, _, infos) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.unlock(now: after(20))
        XCTAssertEqual(s.phase, .working)
        s.tick(now: after(21))
        XCTAssertEqual(infos().last!.remaining, 59, accuracy: 0.001) // 新工作周期从 unlock 起算
    }

    // unlock 在非 resting 相位无效
    func testUnlockIgnoredOutsideResting() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.unlock(now: after(10))
        XCTAssertEqual(s.phase, .working)
        s.tick(now: after(59))
        XCTAssertEqual(s.phase, .working)  // 工作计时没被重置也没被打断
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
    }

    // pause 仅 working/warning 可用;resting 中无效
    func testPauseIgnoredDuringResting() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.pause(now: after(10))
        XCTAssertEqual(s.phase, .resting)
    }

    // 暂停 1 小时后自动恢复
    func testPauseAutoResumesAfterOneHour() {
        let (s, phases, _) = makeScheduler(makeConfig())
        s.pause(now: after(10))
        XCTAssertEqual(s.phase, .paused)
        s.tick(now: after(3609))
        XCTAssertEqual(s.phase, .paused)
        s.tick(now: after(3610))          // 10 + 3600
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(phases(), [.paused, .working])
    }

    // 提前恢复:工作计时重开
    func testResumeEarlyRestartsWork() {
        let (s, _, infos) = makeScheduler(makeConfig())
        s.pause(now: after(10))
        s.resume(now: after(100))
        XCTAssertEqual(s.phase, .working)
        s.tick(now: after(101))
        XCTAssertEqual(infos().last!.remaining, 59, accuracy: 0.001)
    }

    // reload:working 中按新时长重开
    func testReloadDuringWorkingRestartsWithNewDuration() {
        let (s, _, infos) = makeScheduler(makeConfig(work: 1))
        var newConfig = makeConfig(work: 2)
        newConfig.message = "新配置"
        s.reload(config: newConfig, now: after(30))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.config.message, "新配置")
        s.tick(now: after(31))
        XCTAssertEqual(infos().last!.remaining, 119, accuracy: 0.001) // 2 分钟从 reload 起算
    }

    // reload:resting 中不动当前 deadline
    func testReloadDuringRestingKeepsRestDeadline() {
        let (s, _, _) = makeScheduler(makeConfig(rest: 1))
        s.breakNow(now: t0)
        s.reload(config: makeConfig(rest: 10), now: after(30))
        XCTAssertEqual(s.phase, .resting)
        s.tick(now: after(60))            // 原 deadline 到点即解除
        XCTAssertEqual(s.phase, .working)
    }

    // 唤醒:短睡眠顺延 deadline(计时暂停语义)
    func testWakeShortSleepExtendsWorkDeadline() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.systemDidWake(sleptFor: 10, now: after(30))
        s.tick(now: after(65))
        XCTAssertEqual(s.phase, .working)  // 原 60 顺延到 70
        s.tick(now: after(70))
        XCTAssertEqual(s.phase, .warning)
    }

    // 唤醒:睡够一次休息时长,视为已休息,工作重开
    func testWakeLongSleepResetsWork() {
        let (s, _, infos) = makeScheduler(makeConfig())
        s.systemDidWake(sleptFor: 3600, now: after(3630))
        XCTAssertEqual(s.phase, .working)
        s.tick(now: after(3630))
        XCTAssertEqual(infos().last!.remaining, 60, accuracy: 0.001)
    }

    // 唤醒:resting 已过点 → 直接解除
    func testWakeDuringRestPastDeadlineEndsRest() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 120, now: after(120))
        XCTAssertEqual(s.phase, .working)
    }

    // 唤醒:resting 未过点 → 继续休息(墙钟)
    func testWakeDuringRestBeforeDeadlineKeepsResting() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 10, now: after(10))
        XCTAssertEqual(s.phase, .resting)
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .working)
    }

    // 解锁按钮:延迟出现
    func testUnlockVisibilityDelayed() {
        let (s, _, infos) = makeScheduler(makeConfig(unlock: .seconds(30)))
        s.breakNow(now: t0)
        s.tick(now: after(29))
        XCTAssertFalse(infos().last!.unlockVisible)
        s.tick(now: after(30))
        XCTAssertTrue(infos().last!.unlockVisible)
    }

    // 解锁按钮:never 永不出现
    func testUnlockVisibilityNever() {
        let (s, _, infos) = makeScheduler(makeConfig(unlock: .never))
        s.breakNow(now: t0)
        s.tick(now: after(59))
        XCTAssertFalse(infos().last!.unlockVisible)
    }

    // 解锁按钮:0 = 一开始就显示;非 resting 相位恒为 false
    func testUnlockVisibilityImmediate() {
        let (s, _, infos) = makeScheduler(makeConfig(unlock: .seconds(0)))
        s.tick(now: after(1))
        XCTAssertFalse(infos().last!.unlockVisible)   // working 中无按钮
        s.breakNow(now: after(2))
        s.tick(now: after(2))
        XCTAssertTrue(infos().last!.unlockVisible)
    }

    // tick 上报剩余秒
    func testTickReportsRemaining() {
        let (s, _, infos) = makeScheduler(makeConfig())
        s.tick(now: after(1))
        XCTAssertEqual(infos().last!.remaining, 59, accuracy: 0.001)
        XCTAssertEqual(infos().last!.phase, .working)
    }
}
