import Foundation

public enum Phase: Equatable {
    case working, warning, resting, paused
}

public struct TickInfo: Equatable {
    public var phase: Phase
    public var remaining: TimeInterval
    public var unlockVisible: Bool
}

public enum RestEndReason: Equatable {
    case completed   // 休息时间自然走完
    case unlocked    // 手动解锁(按钮/ESC 后门)
    case wake        // 睡眠/锁屏期间到期,唤醒时解除
}

public final class BreakScheduler {

    public var onPhaseChange: ((Phase) -> Void)?
    public var onTick: ((TickInfo) -> Void)?
    public var onRestEnded: ((RestEndReason) -> Void)?

    public private(set) var phase: Phase = .working
    public private(set) var skipNextArmed = false
    public private(set) var config: Config

    /// 连续暂停/跳过次数;每次真的休息完归零。达 max_consecutive_skips 后暂停与跳过均被拒绝。
    public private(set) var consecutiveSkips = 0

    public static let pauseDuration: TimeInterval = 3600

    private var deadline: Date          // 当前相位结束时刻
    private var restStartedAt: Date?    // resting 进入时刻(解锁按钮计时基准)

    public init(config: Config, now: Date) {
        self.config = config
        self.deadline = now.addingTimeInterval(config.workMinutes * 60)
    }

    // MARK: - 驱动

    public func tick(now: Date) {
        if now >= deadline {
            switch phase {
            case .working, .warning:
                if phase == .working, config.warnSeconds > 0, !skipNextArmed {
                    transition(to: .warning,
                               deadline: now.addingTimeInterval(TimeInterval(config.warnSeconds)))
                } else if skipNextArmed {
                    skipNextArmed = false
                    startWork(now: now)
                } else {
                    startRest(now: now)
                }
            case .resting:
                endRest(now: now, reason: .completed, restWasFull: true)
            case .paused:
                startWork(now: now)
            }
        }
        onTick?(tickInfo(now: now))
    }

    // MARK: - 动作

    public func breakNow(now: Date) {
        guard phase != .resting else { return }
        skipNextArmed = false
        startRest(now: now)
    }

    public func toggleSkipNext() {
        skipNextArmed.toggle()
    }

    @discardableResult
    public func pause(now: Date) -> Bool {
        guard phase == .working || phase == .warning else { return false }
        guard !skipsExhausted else { return false }
        consecutiveSkips += 1
        transition(to: .paused, deadline: now.addingTimeInterval(Self.pauseDuration))
        return true
    }

    public func resume(now: Date) {
        guard phase == .paused else { return }
        startWork(now: now)
    }

    public func unlock(now: Date) {
        guard phase == .resting else { return }
        // now >= deadline 只在「已到点但本秒 tick 还没跑」的 ~1 秒窗口内为真,此时休息其实已走完。
        endRest(now: now, reason: .unlocked, restWasFull: now >= deadline)
    }

    public func reload(config: Config, now: Date) {
        self.config = config
        if phase == .working || phase == .warning {
            startWork(now: now)
        }
        // resting/paused:新配置自下个周期生效,当前 deadline 不动
    }

    public func systemDidWake(sleptFor: TimeInterval, now: Date) {
        // 睡/离开够一次休息时长 = 视为已休息,任何相位一律清零(含 .paused;
        // 必须在 switch 之前,否则暂停中合盖过夜回来计数仍是满的)。
        if sleptFor >= config.restMinutes * 60 { consecutiveSkips = 0 }

        switch phase {
        case .resting:
            if now >= deadline {
                endRest(now: now, reason: .wake, restWasFull: true)
            } else if config.wakeEndsRest {
                // 未到点被掐断:离开/睡眠够一次休息时长也算休息过了,否则记一次逃避。
                // 离开可早于休息开始(离开期间计时不冻结),故 now < deadline 不等于「没休息够」。
                endRest(now: now, reason: .wake, restWasFull: sleptFor >= config.restMinutes * 60)
            }
            // 未到点且 wake_ends_rest = off:遮罩继续,按墙钟走
        case .working, .warning:
            if sleptFor >= config.restMinutes * 60 {
                startWork(now: now)                              // 睡够了,视为已休息
            } else {
                deadline = deadline.addingTimeInterval(sleptFor) // 睡眠期间计时暂停
            }
        case .paused:
            break                                                // 暂停按墙钟,不补偿
        }
    }

    public func unlockVisible(now: Date) -> Bool {
        guard phase == .resting, let start = restStartedAt else { return false }
        switch config.unlockAfter {
        case .never:
            return false
        case .seconds(let s):
            return now.timeIntervalSince(start) >= TimeInterval(s)
        }
    }

    // MARK: - 私有

    /// 0 = 不限。
    private var skipsExhausted: Bool {
        config.maxConsecutiveSkips > 0 && consecutiveSkips >= config.maxConsecutiveSkips
    }

    /// 结束休息:跑满了就清零连续计数;没跑满则算一次逃避 +1(require_full_rest = off 时一律清零)。
    /// startWork 在前、onRestEnded 在后,维持既有回调顺序(见 testRestEndReasonFiresAfterPhaseChange)。
    private func endRest(now: Date, reason: RestEndReason, restWasFull: Bool) {
        if restWasFull || !config.requireFullRest {
            consecutiveSkips = 0
        } else {
            consecutiveSkips += 1        // 没跑满 = 一次逃避,占额度
        }
        startWork(now: now)
        onRestEnded?(reason)
    }

    private func startWork(now: Date) {
        restStartedAt = nil
        transition(to: .working, deadline: now.addingTimeInterval(config.workMinutes * 60))
    }

    private func startRest(now: Date) {
        restStartedAt = now
        transition(to: .resting, deadline: now.addingTimeInterval(config.restMinutes * 60))
    }

    private func transition(to newPhase: Phase, deadline: Date) {
        self.deadline = deadline
        if phase != newPhase {
            phase = newPhase
            onPhaseChange?(newPhase)
        }
    }

    private func tickInfo(now: Date) -> TickInfo {
        TickInfo(phase: phase,
                 remaining: max(0, deadline.timeIntervalSince(now)),
                 unlockVisible: unlockVisible(now: now))
    }
}
