import AppKit
import RestEyesCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var scheduler: BreakScheduler!
    private let overlay = OverlayController()
    private let statusItem = StatusItemController()
    private var tickTimer: Timer?
    private var absenceBeganAt: Date?
    private var isAsleep = false
    private var isScreenLocked = false

    /// 休息自然结束触发的锁屏尚未撤除黑窗时为 true(等 screenIsLocked 或兜底超时后撤)。
    private var pendingRestWindowRemoval = false
    private var lockConfirmFallbackTimer: Timer?

    /// 缺席看门狗上限:锁屏/唤醒通知丢失时,超过上限强制结束缺席,避免计时永久冻结
    private static let absenceForceClearCeiling: TimeInterval = 3600

    /// 锁屏后等待锁屏界面盖上的兜底上限:超时仍未收到 screenIsLocked 就直接撤黑窗,防滞留。
    private static let lockConfirmFallback: TimeInterval = 2.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()
        let config = Config.load()
        scheduler = BreakScheduler(config: config, now: Date())
        LoginItem.sync(enabled: config.launchAtLogin)
        wire()
        startTicking()
        observeSleepAndLock()
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
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let began = self.absenceBeganAt {
                if Date().timeIntervalSince(began) >= Self.absenceForceClearCeiling {
                    self.isAsleep = false
                    self.isScreenLocked = false
                    self.endAbsenceIfPresent()
                }
                return
            }
            self.scheduler.tick(now: Date())
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)   // 菜单打开(eventTracking)时也要走时
        tickTimer = timer
    }

    // MARK: - 睡眠/锁屏

    private func observeSleepAndLock() {
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = true
            self?.noteAbsenceBegan()
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = false
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
    }

    private func noteAbsenceBegan() {
        if absenceBeganAt == nil { absenceBeganAt = Date() }
    }

    private func endAbsenceIfPresent() {
        guard !isAsleep, !isScreenLocked, let began = absenceBeganAt else { return }
        absenceBeganAt = nil
        scheduler.systemDidWake(sleptFor: Date().timeIntervalSince(began), now: Date())
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
