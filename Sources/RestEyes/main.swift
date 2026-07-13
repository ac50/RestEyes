import AppKit
import CoreGraphics
import RestEyesCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var scheduler: BreakScheduler!
    private let overlay = OverlayController()
    private let statusItem = StatusItemController()
    private var tickTimer: Timer?
    private var lastTickAt = Date()            // 上次心跳时刻;侦测系统挂起(睡眠/合盖)造成的时钟跳变
    private var absenceBeganAt: Date?
    private var isScreenLocked = false
    private var isDisplayAsleep = false        // 显示器熄屏(补「纯熄屏无通知」缺口)
    private var isScreensaverActive = false    // 屏保运行中

    /// 休息自然结束触发的锁屏尚未撤除黑窗时为 true(等 screenIsLocked 或兜底超时后撤)。
    private var pendingRestWindowRemoval = false
    private var lockConfirmFallbackTimer: Timer?

    /// 缺席看门狗上限:锁屏/唤醒通知丢失时,超过上限强制结束缺席,避免计时永久冻结
    private static let absenceForceClearCeiling: TimeInterval = 3600

    /// 锁屏后等待锁屏界面盖上的兜底上限:超时仍未收到 screenIsLocked 就直接撤黑窗,防滞留。
    private static let lockConfirmFallback: TimeInterval = 2.5

    /// 缺席结束轮询去抖:离开不足此秒数不触发轮询解冻,避免刚锁屏那一瞬会话态未落定被误判为「在场」。
    private static let absencePollDebounce: TimeInterval = 3

    /// 心跳间隔远超正常 1 秒即判定中间被系统挂起(睡眠/合盖);挂起时长交给 systemDidWake 对账。
    /// 误报(主线程偶发卡顿)只会把 deadline 顺移几秒,无害。
    private static let suspendJumpThreshold: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()
        let config = Config.load()
        scheduler = BreakScheduler(config: config, now: Date())
        LoginItem.sync(enabled: config.launchAtLogin)
        wire()
        startTicking()
        observeAbsenceNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.hideRest()   // 保险:退出路径下还原 presentationOptions
    }

    // MARK: - 组装

    private func wire() {
        scheduler.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .working:
                overlay.hideWarning()
                // 撤休息遮罩改由 onRestEnded 统一收口(见下),以支持「锁屏前不撤窗」。
                reloadConfigIfChanged()      // 每个工作周期开始自动重读配置
            case .warning:
                overlay.showWarning(secondsRemaining: scheduler.config.warnSeconds)
            case .resting:
                overlay.hideWarning()
                overlay.showRest(config: scheduler.config)
            case .paused:
                overlay.hideWarning()
            }
        }

        scheduler.onTick = { [weak self] info in
            guard let self else { return }
            switch info.phase {
            case .warning:
                overlay.showWarning(secondsRemaining: Int(info.remaining.rounded()))
            case .resting:
                overlay.updateRest(remaining: info.remaining,
                                   unlockVisible: info.unlockVisible)
            case .working, .paused:
                break
            }
            statusItem.update(phase: info.phase, remaining: info.remaining,
                              skipNextArmed: scheduler.skipNextArmed)
        }

        // 退出 resting 只有 completed/unlocked/wake 三条路,每条都经此回调,故这里是撤遮罩的唯一收口。
        scheduler.onRestEnded = { [weak self] reason in
            guard let self else { return }
            if reason == .completed, self.scheduler.config.lockAfterRest {
                // 休息自然结束且要锁屏:先停交互(让用户能输密码),黑窗保留;
                // 锁屏后等 screenIsLocked(锁屏界面盖上)再撤黑窗,避免中途露出桌面。
                self.overlay.detachRestInteraction()
                ScreenLocker.lock()
                self.pendingRestWindowRemoval = true
                self.startLockConfirmFallback()
            } else {
                self.overlay.hideRest()
            }
        }

        overlay.onUnlockRequested = { [weak self] in
            self?.scheduler.unlock(now: Date())
        }

        statusItem.onBreakNow = { [weak self] in self?.scheduler.breakNow(now: Date()) }
        statusItem.onToggleSkipNext = { [weak self] in self?.scheduler.toggleSkipNext() }
        statusItem.onPauseToggle = { [weak self] in
            guard let self else { return }
            if scheduler.phase == .paused {
                scheduler.resume(now: Date())
            } else {
                scheduler.pause(now: Date())
            }
        }
        statusItem.onOpenConfig = {
            _ = Config.load()                          // 确保文件存在
            NSWorkspace.shared.open(Config.defaultURL)
        }
        statusItem.onReloadConfig = { [weak self] in
            let fresh = Config.load()
            self?.scheduler.reload(config: fresh, now: Date())
            LoginItem.sync(enabled: fresh.launchAtLogin)
        }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    private func reloadConfigIfChanged() {
        let fresh = Config.load()
        if fresh != scheduler.config {
            scheduler.reload(config: fresh, now: Date())
            LoginItem.sync(enabled: fresh.launchAtLogin)
        }
    }

    // MARK: - 心跳

    private func startTicking() {
        lastTickAt = Date()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.lastTickAt)
            self.lastTickAt = now

            if let began = self.absenceBeganAt {
                // 已登记缺席(醒着但人不在:锁屏/熄屏/屏保):按墙钟冻结,靠看门狗上限或
                // 「离开够久 + 已在场」轮询结束(后者补漏收的唤醒/解锁通知)。
                let awayFor = now.timeIntervalSince(began)
                if awayFor >= Self.absenceForceClearCeiling
                    || (awayFor >= Self.absencePollDebounce && self.userIsPresent()) {
                    self.endAbsence(awayFor: awayFor)
                }
                return
            }
            if gap >= Self.suspendJumpThreshold {
                // 心跳间隔异常大 = 中间被系统挂起(睡眠/合盖)却未登记缺席:按跳变时长对账。
                // 休息相位也刻意走这条(未登记的挂起中断休息 → 交 systemDidWake 按 wake_ends_rest 处理,
                // 才是真挂起时的正确行为);理论上 ≥5s 主线程卡顿会误判、提前结束休息,但本应用几乎
                // 不可能卡这么久,可接受 —— 勿为此把休息相位排除掉。
                self.scheduler.systemDidWake(sleptFor: gap, now: now)
                return
            }
            self.scheduler.tick(now: now)
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)   // 菜单打开(eventTracking)时也要走时
        tickTimer = timer
    }

    // MARK: - 缺席检测(醒着但人不在:锁屏/熄屏/屏保)
    //         系统挂起(睡眠/合盖:CPU 关、时钟跳)由心跳的时钟跳变兜底,不在此处理。

    private func observeAbsenceNotifications() {
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayAsleep = true
            self?.noteAbsenceBegan()
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayAsleep = false
            self?.endAbsenceIfPresent()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = true
            self?.noteAbsenceBegan()
            self?.finishPendingRestWindowRemoval()   // 锁屏界面已盖上 → 撤掉延迟保留的黑窗
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = false
            self?.endAbsenceIfPresent()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreensaverActive = true
            self?.noteAbsenceBegan()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreensaverActive = false
            self?.endAbsenceIfPresent()
        }
    }

    private func noteAbsenceBegan() {
        if absenceBeganAt == nil { absenceBeganAt = Date() }
    }

    private func endAbsenceIfPresent() {
        guard !isScreenLocked, !isDisplayAsleep, !isScreensaverActive,
              let began = absenceBeganAt else { return }
        endAbsence(awayFor: Date().timeIntervalSince(began))
    }

    /// 强制结束缺席:复位全部缺席标记并按给定离开时长对账。看门狗与轮询兜底共用此收口。
    private func endAbsence(awayFor: TimeInterval) {
        isScreenLocked = false
        isDisplayAsleep = false
        isScreensaverActive = false
        absenceBeganAt = nil
        scheduler.systemDidWake(sleptFor: awayFor, now: Date())
    }

    /// 缺席期间轮询:用户是否已回到(屏保未运行 且 显示器未睡 且 屏幕未锁)。
    private func userIsPresent() -> Bool {
        if isScreensaverActive { return false }                        // 屏保运行中(屏未锁、屏未熄)→ 仍不在
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }   // 显示器在睡 → 仍不在
        if screenIsLockedNow() { return false }                        // 屏幕锁定中 → 仍不在
        return true
    }

    /// 读当前会话锁屏态(CGSSessionScreenIsLocked,CFBoolean → Bool)。读不到时保守返回 false,
    /// 由 userIsPresent 结合显示器态共同判定。
    private func screenIsLockedNow() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func startLockConfirmFallback() {
        lockConfirmFallbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lockConfirmFallback, repeats: false) { [weak self] _ in
            self?.finishPendingRestWindowRemoval()
        }
        RunLoop.main.add(timer, forMode: .common)
        lockConfirmFallbackTimer = timer
    }

    /// 撤除延迟锁屏路保留的黑窗。由 screenIsLocked 观察者(正常)或兜底计时器(降级)调用,幂等。
    private func finishPendingRestWindowRemoval() {
        guard pendingRestWindowRemoval else { return }
        pendingRestWindowRemoval = false
        lockConfirmFallbackTimer?.invalidate()
        lockConfirmFallbackTimer = nil
        overlay.removeRestWindows()
    }

    // MARK: - 单实例

    private func terminateIfAlreadyRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }  // 裸二进制无 bundle,跳过
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
