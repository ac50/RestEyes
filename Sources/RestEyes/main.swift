import AppKit
import RestEyesCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var scheduler: BreakScheduler!
    private let overlay = OverlayController()
    private let statusItem = StatusItemController()
    private var tickTimer: Timer?
    private var lastTickAt = Date()            // 上次心跳时刻;侦测系统挂起(睡眠/合盖)造成的时钟跳变
    private var awayBeganAt: Date?            // 离开(锁屏/熄屏/屏保)起点;不冻结,仅用于回来时算离开时长
    private var isScreenLocked = false
    private var isDisplayAsleep = false        // 显示器熄屏(补「纯熄屏无通知」缺口)
    private var isScreensaverActive = false    // 屏保运行中

    /// 休息自然结束触发的锁屏尚未撤除黑窗时为 true(等 screenIsLocked 或兜底超时后撤)。
    private var pendingRestWindowRemoval = false
    private var lockConfirmFallbackTimer: Timer?

    /// 锁屏确认后再等这点时间(合成缓冲),让锁屏界面完全画完再撤黑窗,消除露桌面那一帧。
    private static let lockRemovalGrace: TimeInterval = 0.4

    /// 兜底硬上限:超时仍没收到 screenIsLocked 就直接撤黑窗,防滞留。
    /// 常态走「通知 + 缓冲」快路(几百毫秒内撤),兜底几乎不触发。
    private static let lockConfirmFallback: TimeInterval = 5

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
        observeAwayNotifications()
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
                if !isAway { overlay.showWarning(secondsRemaining: scheduler.config.warnSeconds) }
            case .resting:
                overlay.hideWarning()
                if !isAway { overlay.showRest(config: scheduler.config) }
            case .paused:
                overlay.hideWarning()
            }
        }

        scheduler.onTick = { [weak self] info in
            guard let self else { return }
            switch info.phase {
            case .warning:
                if !isAway { overlay.showWarning(secondsRemaining: Int(info.remaining.rounded())) }
            case .resting:
                overlay.updateRest(remaining: info.remaining,
                                   unlockVisible: info.unlockVisible)
            case .working, .paused:
                break
            }
            statusItem.update(phase: info.phase, remaining: info.remaining,
                              skipNextArmed: scheduler.skipNextArmed,
                              skipsExhausted: info.skipsExhausted)
        }

        // 退出 resting 只有 completed/unlocked/wake 三条路,都经此回调。
        // 是否锁屏由胶水层依配置决定;离开期间(isAway)一律不锁,只撤遮罩。
        scheduler.onRestEnded = { [weak self] reason in
            guard let self else { return }
            let shouldLock = !self.isAway && (
                (reason == .completed && self.scheduler.config.lockAfterRest) ||
                (reason == .unlocked  && self.scheduler.config.lockOnUnlock)
            )
            if shouldLock {
                // 先停交互(让用户能输密码),黑窗保留;锁屏后再撤黑窗(见 Task 3 的确认撤窗)。
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

            if gap >= Self.suspendJumpThreshold {
                // 心跳间隔异常大 = 系统被挂起(睡眠/合盖)。按跳变时长对账,交 systemDidWake 处理。
                self.scheduler.systemDidWake(sleptFor: gap, now: now)
                return
            }
            self.scheduler.tick(now: now)          // 离开(锁屏/熄屏/屏保)时也照常走,不冻结
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)   // 菜单打开(eventTracking)时也要走时
        tickTimer = timer
    }

    // MARK: - 离开检测(锁屏/熄屏/屏保);不冻结计时,仅在回来时按离开时长决定是否重置。
    //         系统挂起(睡眠/合盖:CPU 关、时钟跳)由心跳的时钟跳变兜底,不在此处理。
    private func observeAwayNotifications() {
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayAsleep = true
            self?.noteAwayBegan()
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayAsleep = false
            self?.reconcileIfBack()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = true
            self?.noteAwayBegan()
            self?.scheduleRemovalAfterGrace()   // 锁屏确认 → 等合成缓冲后撤黑窗(见下)
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = false
            self?.reconcileIfBack()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreensaverActive = true
            self?.noteAwayBegan()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreensaverActive = false
            self?.reconcileIfBack()
        }
    }

    /// 是否处于「离开」态(锁屏/熄屏/屏保任一)。用于抑制离开期间的休息 UI 与锁屏。
    private var isAway: Bool { isScreenLocked || isDisplayAsleep || isScreensaverActive }

    private func noteAwayBegan() {
        if awayBeganAt == nil { awayBeganAt = Date() }
    }

    /// 三个离开标记全清(解锁 且 亮屏 且 屏保停)= 用户真回来了 → 收口对账,一律落在工作态。
    /// 计时器离开期间照常走,故这里只在「离开够久」时重置;短暂离开不动(不补偿)。
    private func reconcileIfBack() {
        guard !isScreenLocked, !isDisplayAsleep, !isScreensaverActive,
              let began = awayBeganAt else { return }
        awayBeganAt = nil
        let now = Date()
        let awayFor = now.timeIntervalSince(began)
        switch scheduler.phase {
        case .resting:
            // 离开期间进了休息(遮罩被抑制):结束它。wake_ends_rest=on 回工作;
            // off 且未到点则休息继续,此时把遮罩显示出来(与该开关语义一致)。
            scheduler.systemDidWake(sleptFor: awayFor, now: now)
            if scheduler.phase == .resting {
                overlay.showRest(config: scheduler.config)   // 下一次 onTick 会刷新倒计时
            }
        case .working, .warning:
            if awayFor >= scheduler.config.restMinutes * 60 {
                scheduler.systemDidWake(sleptFor: awayFor, now: now)   // → startWork 全新工作
            }
            // < rest_minutes:什么都不做(计时器本就照常走着)
        case .paused:
            // 仅为「离开够久 → 清零连续计数」;systemDidWake 的 .paused 分支不动暂停 deadline。
            scheduler.systemDidWake(sleptFor: awayFor, now: now)
        }
    }

    /// 兜底上限(约 5s):超时仍未收到 screenIsLocked 就直接撤黑窗,防滞留。
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

    /// 收到 com.apple.screenIsLocked 后,等一个合成缓冲再撤黑窗:此刻锁屏界面已在黑窗之上,
    /// 撤窗发生在其下方、不可见。非「休息结束锁屏」路(pending 为假)时安全 no-op。
    private func scheduleRemovalAfterGrace() {
        guard pendingRestWindowRemoval else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockRemovalGrace) { [weak self] in
            self?.finishPendingRestWindowRemoval()
        }
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
