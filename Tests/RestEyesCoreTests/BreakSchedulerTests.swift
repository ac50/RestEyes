import XCTest
@testable import RestEyesCore

final class BreakSchedulerTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func after(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func makeConfig(work: Double = 1, rest: Double = 1, warn: Int = 10,
                            unlock: UnlockAfter = .seconds(60),
                            maxSkips: Int = 2, requireFullRest: Bool = true) -> Config {
        var c = Config()
        c.workMinutes = work      // 1 分钟 = 60 秒,便于推算
        c.restMinutes = rest
        c.warnSeconds = warn
        c.unlockAfter = unlock
        c.maxConsecutiveSkips = maxSkips
        c.requireFullRest = requireFullRest
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

    // 唤醒:resting 未过点且 wake_ends_rest = off → 继续休息(墙钟)
    func testWakeDuringRestBeforeDeadlineKeepsRestingWhenDisabled() {
        var config = makeConfig()
        config.wakeEndsRest = false
        let (s, _, _) = makeScheduler(config)
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

    // reload 在 paused 中不打断暂停
    func testReloadWhilePausedKeepsPause() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.pause(now: after(10))
        s.reload(config: makeConfig(work: 2), now: after(20))
        XCTAssertEqual(s.phase, .paused)
        s.tick(now: after(3609))
        XCTAssertEqual(s.phase, .paused)
        s.tick(now: after(3610))
        XCTAssertEqual(s.phase, .working)
    }

    // breakNow 在 paused 中直接进入休息
    func testBreakNowFromPausedEntersResting() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.pause(now: after(10))
        s.breakNow(now: after(20))
        XCTAssertEqual(s.phase, .resting)
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .working)
    }

    // 休息结束原因:自然走完
    func testRestEndReasonCompleted() {
        let (s, _, _) = makeScheduler(makeConfig())
        var reasons: [RestEndReason] = []
        s.onRestEnded = { reasons.append($0) }
        s.breakNow(now: t0)
        s.tick(now: after(60))
        XCTAssertEqual(reasons, [.completed])
    }

    // 休息结束原因:手动解锁
    func testRestEndReasonUnlocked() {
        let (s, _, _) = makeScheduler(makeConfig())
        var reasons: [RestEndReason] = []
        s.onRestEnded = { reasons.append($0) }
        s.breakNow(now: t0)
        s.unlock(now: after(20))
        XCTAssertEqual(reasons, [.unlocked])
    }

    // 休息结束原因:唤醒时到期解除
    func testRestEndReasonWake() {
        let (s, _, _) = makeScheduler(makeConfig())
        var reasons: [RestEndReason] = []
        s.onRestEnded = { reasons.append($0) }
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 120, now: after(120))
        XCTAssertEqual(reasons, [.wake])
    }

    // 非休息结束的相位迁移不触发
    func testRestEndReasonNotFiredOnOtherTransitions() {
        let (s, _, _) = makeScheduler(makeConfig())
        var reasons: [RestEndReason] = []
        s.onRestEnded = { reasons.append($0) }
        s.tick(now: after(60))    // working → warning
        s.tick(now: after(70))    // warning → resting(进入,非结束)
        XCTAssertTrue(reasons.isEmpty)
        s.tick(now: after(130))   // resting 到期
        XCTAssertEqual(reasons, [.completed])
    }

    // 回调在 onPhaseChange(.working) 之后触发
    func testRestEndReasonFiresAfterPhaseChange() {
        let (s, _, _) = makeScheduler(makeConfig())
        var order: [String] = []
        s.onPhaseChange = { if $0 == .working { order.append("phase") } }
        s.onRestEnded = { _ in order.append("ended") }
        s.breakNow(now: t0)
        s.tick(now: after(60))
        XCTAssertEqual(order, ["phase", "ended"])
    }

    // wake_ends_rest = off 时唤醒未到点继续休息:不触发结束回调
    func testRestEndReasonNotFiredWhenWakeKeepsResting() {
        var config = makeConfig()
        config.wakeEndsRest = false
        let (s, _, _) = makeScheduler(config)
        var reasons: [RestEndReason] = []
        s.onRestEnded = { reasons.append($0) }
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 10, now: after(10))
        XCTAssertTrue(reasons.isEmpty)
    }

    // 默认 wake_ends_rest = on:未到点解锁直接结束休息进入工作,原因 .wake
    func testWakeDuringRestBeforeDeadlineEndsRestByDefault() {
        let (s, _, infos) = makeScheduler(makeConfig())
        var reasons: [RestEndReason] = []
        s.onRestEnded = { reasons.append($0) }
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 10, now: after(10))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(reasons, [.wake])
        s.tick(now: after(11))
        XCTAssertEqual(infos().last!.remaining, 59, accuracy: 0.001)  // 新工作周期从解锁起算
    }

    // pause 成功:返回 true 且记 1 次
    func testPauseCountsOnce() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // 达上限:pause 返回 false,相位不变、计数不变
    func testPauseRejectedWhenExhausted() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertTrue(s.pause(now: after(30)))
        s.resume(now: after(40))
        XCTAssertEqual(s.consecutiveSkips, 2)
        XCTAssertFalse(s.pause(now: after(50)))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 2)
    }

    // 相位守卫在计数之前:resting 中 pause 被拒且不计数
    // (warning → resting 恰在点击瞬间切换的竞态下,不得记下一次根本没发生的暂停)
    func testPauseInRestingDoesNotCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        XCTAssertFalse(s.pause(now: after(10)))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 提前恢复不退还
    func testResumeDoesNotRefund() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(100))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // max_consecutive_skips = 0 → 不限
    func testMaxZeroNeverRejects() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 0))
        for i in 0..<10 {
            XCTAssertTrue(s.pause(now: after(TimeInterval(i * 10))))
            s.resume(now: after(TimeInterval(i * 10 + 5)))
        }
        XCTAssertEqual(s.consecutiveSkips, 10)
    }

    // max_consecutive_skips = 1 → 不允许连续:第二次即被拒
    func testMaxOneRejectsSecond() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertFalse(s.pause(now: after(30)))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // 休息自然走完 → 清零
    func testCompletedRestResetsCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.breakNow(now: after(30))
        s.tick(now: after(90))                          // 休息 60 秒走完
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // unlock 未到点 + require_full_rest = on → +1
    func testUnlockEarlyCountsWhenFullRestRequired() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.unlock(now: after(20))                        // rest = 60s,未到点
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // unlock 未到点 + require_full_rest = off → 清零
    func testUnlockEarlyResetsWhenFullRestNotRequired() {
        let (s, _, _) = makeScheduler(makeConfig(requireFullRest: false))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.breakNow(now: after(30))
        s.unlock(now: after(40))
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // unlock 在 deadline 之后调用(「已到点但本秒 tick 还没跑」的窗口)→ 清零
    func testUnlockAfterDeadlineResets() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.breakNow(now: after(30))                      // 休息 60 秒 → deadline = 90
        s.unlock(now: after(91))
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // systemDidWake:休息已到点 → 清零
    func testWakePastRestDeadlineResets() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.breakNow(now: after(30))                      // deadline = 90
        s.systemDidWake(sleptFor: 5, now: after(95))
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // systemDidWake:休息未到点 + 短离开 + require_full_rest = on → +1
    // 这是「休息一开始就合盖 6 秒」那条零成本逃避路径,决策 9 要堵的正是它。
    func testShortWakeDuringRestCountsAsEscape() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 6, now: after(6))     // rest = 60s 未到点
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // systemDidWake:休息未到点但离开 >= rest_minutes → 清零
    // 离开可以早于休息开始(离开期间计时不冻结),故会出现「离开很久但休息刚开始」——不该被罚。
    func testLongAwayDuringRestResetsEvenBeforeDeadline() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.breakNow(now: after(30))                      // deadline = 90
        s.systemDidWake(sleptFor: 70, now: after(80))   // 离开 70s >= rest 60s,但 now < deadline
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // systemDidWake:休息未到点 + wake_ends_rest = off → 休息继续,计数既不清零也不 +1
    func testWakeWithWakeEndsRestOffLeavesCountUntouched() {
        var c = makeConfig()
        c.wakeEndsRest = false
        let (s, _, _) = makeScheduler(c)
        XCTAssertTrue(s.pause(now: after(10)))   // count = 1
        s.resume(now: after(20))
        s.breakNow(now: after(30))               // rest deadline = 90
        s.systemDidWake(sleptFor: 6, now: after(36))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(s.consecutiveSkips, 1)    // 不清零、不 +1
    }

    // 连掐 max 次不完整休息后 pause 被拒 —— 钉死决策 9 真的堵住了那条路
    func testRepeatedShortWakesExhaustBudget() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 6, now: after(6))     // +1
        s.breakNow(now: after(10))
        s.systemDidWake(sleptFor: 6, now: after(16))    // +1
        XCTAssertEqual(s.consecutiveSkips, 2)
        XCTAssertFalse(s.pause(now: after(20)))
    }

    // 工作中长睡 >= rest_minutes → 清零
    func testLongSleepInWorkingResets() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.systemDidWake(sleptFor: 60, now: after(80))   // rest = 60s
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 工作中短睡 → 不清零、不消耗 armed skip
    func testShortSleepInWorkingKeepsCountAndArm() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.toggleSkipNext()
        s.systemDidWake(sleptFor: 10, now: after(30))
        XCTAssertEqual(s.consecutiveSkips, 1)
        XCTAssertTrue(s.skipNextArmed)
    }

    // .paused 相位长睡 → 清零,且暂停 deadline 不变(清零提到 switch 之前才成立)
    func testLongSleepWhilePausedResetsButKeepsPause() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertTrue(s.pause(now: after(30)))          // 计数 = 2,已满;暂停至 3630
        XCTAssertEqual(s.consecutiveSkips, 2)
        s.systemDidWake(sleptFor: 60, now: after(90))
        XCTAssertEqual(s.consecutiveSkips, 0)
        XCTAssertEqual(s.phase, .paused)                // 暂停未被打断、不补偿
        s.tick(now: after(3629))
        XCTAssertEqual(s.phase, .paused)
        s.tick(now: after(3630))
        XCTAssertEqual(s.phase, .working)
    }

    // .paused 相位短睡 → 不清零
    func testShortSleepWhilePausedKeepsCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.systemDidWake(sleptFor: 10, now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        XCTAssertEqual(s.phase, .paused)
    }

    // working 中 armed + 未满 → 跳过生效,+1
    func testSkipInWorkingCounts() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .working)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // warning 中 armed + 未满 → 跳过生效,+1(镜像 testSkipNextDuringWarning)
    func testSkipInWarningCounts() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
        s.toggleSkipNext()
        s.tick(now: after(70))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // working 中 armed + 已满 → 作废勾选、照走预警、不计数
    // 落回正常路径而非直接 startRest:armed 时原逻辑绕过预警,拒绝后直接休息会让用户毫无预警地黑屏。
    func testSkipRefusedWhenExhaustedFallsBackToWarning() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))          // 计数 = 1,已满
        s.resume(now: after(20))                        // 工作至 80
        s.toggleSkipNext()
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .warning)               // 该给的预警照给
        XCTAssertFalse(s.skipNextArmed)                 // 勾选被作废
        XCTAssertEqual(s.consecutiveSkips, 1)           // 不计数
        s.tick(now: after(90))
        XCTAssertEqual(s.phase, .resting)               // 预警走完照常休息
    }

    // warning 中 armed + 已满 → 作废勾选、直接休息、不计数
    func testSkipRefusedInWarningGoesToRest() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .warning)
        s.toggleSkipNext()
        s.tick(now: after(90))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // warn_seconds = 0 + armed + 已满 → 直接休息、不计数
    func testSkipRefusedWithZeroWarnGoesToRest() {
        let (s, _, _) = makeScheduler(makeConfig(warn: 0, maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.toggleSkipNext()
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // breakNow 清 armed 是丢弃不是消耗 → 不计数
    func testBreakNowDiscardsArmWithoutCounting() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        s.breakNow(now: after(10))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 反复切换开关不烧计数
    func testTogglingSkipDoesNotCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        for _ in 0..<5 { s.toggleSkipNext(); s.toggleSkipNext() }
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 共用计数池:pause 1 次 + 跳过 1 次 = 2,max = 2 时第三次被拒
    func testPauseAndSkipShareTheSameBudget() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        XCTAssertTrue(s.pause(now: after(10)))          // 1
        s.resume(now: after(20))
        s.toggleSkipNext()
        s.tick(now: after(80))                          // 跳过生效 → 2
        XCTAssertEqual(s.consecutiveSkips, 2)
        XCTAssertFalse(s.pause(now: after(90)))
    }

    // reload 只改 message → deadline 不变(堵「预警中点重新加载配置 = 免费跳过」)
    func testReloadWithoutDurationChangeKeepsDeadline() {
        let (s, _, _) = makeScheduler(makeConfig(work: 1))
        var c = makeConfig(work: 1)
        c.message = "新文案"
        s.reload(config: c, now: after(30))
        XCTAssertEqual(s.config.message, "新文案")
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)               // 原 deadline 未被重置
    }

    // .warning 中 reload → 相位仍是 warning,预警到点照常进 resting
    func testReloadDuringWarningKeepsWarning() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
        var c = makeConfig(work: 5)
        c.message = "改了"
        s.reload(config: c, now: after(65))
        XCTAssertEqual(s.phase, .warning)               // 不被取消
        s.tick(now: after(70))
        XCTAssertEqual(s.phase, .resting)               // 预警走完照常休息
    }

    // reload 不清零计数
    func testReloadKeepsCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.reload(config: makeConfig(work: 2), now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // TickInfo 上报禁用状态
    func testTickInfoReportsSkipsExhausted() {
        let (s, _, infos) = makeScheduler(makeConfig(maxSkips: 1))
        s.tick(now: after(1))
        XCTAssertFalse(infos().last!.skipsExhausted)
        XCTAssertTrue(s.pause(now: after(2)))
        s.tick(now: after(3))
        XCTAssertTrue(infos().last!.skipsExhausted)
    }
}
