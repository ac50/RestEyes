import AppKit
import RestEyesCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var scheduler: BreakScheduler!
    private let overlay = OverlayController()
    private let statusItem = StatusItemController()
    private var tickTimer: Timer?
    private var absenceBeganAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()
        scheduler = BreakScheduler(config: Config.load(), now: Date())
        wire()
        startTicking()
        observeSleepAndLock()
    }

    // MARK: - 组装

    private func wire() {
        scheduler.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .working:
                overlay.hideWarning()
                overlay.hideRest()
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
            self?.scheduler.reload(config: Config.load(), now: Date())
        }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    private func reloadConfigIfChanged() {
        let fresh = Config.load()
        if fresh != scheduler.config {
            scheduler.reload(config: fresh, now: Date())
        }
    }

    // MARK: - 心跳

    private func startTicking() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scheduler.tick(now: Date())
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
            self?.noteAbsenceBegan()
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.noteAbsenceEnded()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.noteAbsenceBegan()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.noteAbsenceEnded()
        }
    }

    private func noteAbsenceBegan() {
        if absenceBeganAt == nil { absenceBeganAt = Date() }
    }

    private func noteAbsenceEnded() {
        guard let began = absenceBeganAt else { return }
        absenceBeganAt = nil
        scheduler.systemDidWake(sleptFor: Date().timeIntervalSince(began), now: Date())
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
