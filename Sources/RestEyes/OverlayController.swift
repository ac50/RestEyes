import AppKit
import RestEyesCore

final class OverlayController: NSObject {

    var onUnlockRequested: (() -> Void)?

    // MARK: - 预警浮窗

    private var warningWindow: NSPanel?
    private var warningLabel: NSTextField?

    func showWarning(secondsRemaining: Int) {
        if warningWindow == nil {
            buildWarningWindow()
        }
        warningLabel?.stringValue = "\(secondsRemaining) 秒后休息"
        if let screen = NSScreen.main, let panel = warningWindow {
            let f = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20, y: f.minY + 20))
        }
        warningWindow?.orderFrontRegardless()
    }

    func hideWarning() {
        warningWindow?.orderOut(nil)
    }

    private func buildWarningWindow() {
        let size = NSSize(width: 200, height: 56)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        content.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        panel.contentView = content
        warningWindow = panel
        warningLabel = label
    }

    // MARK: - 休息遮罩

    private var restWindows: [NSWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var unlockButtons: [NSButton] = []
    private var keyMonitor: Any?
    private var activationTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []

    private var config = Config()
    private var lastRemaining: TimeInterval = 0
    private var lastUnlockVisible = false
    private var escPressCount = 0
    private var lastEscPressAt = Date.distantPast
    private var isShieldActive = false

    func showRest(config: Config) {
        guard !isShieldActive else { return }
        isShieldActive = true
        self.config = config
        lastRemaining = config.restMinutes * 60
        lastUnlockVisible = (config.unlockAfter == .seconds(0))
        escPressCount = 0

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar,
            .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication,
        ]

        buildRestWindows()
        updateRest(remaining: lastRemaining, unlockVisible: lastUnlockVisible)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return nil   // 吞掉所有按键
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.rebuildRestWindows()
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.assertFrontmost()
        }
        RunLoop.main.add(timer, forMode: .common)
        activationTimer = timer

        assertFrontmost()
    }

    func updateRest(remaining: TimeInterval, unlockVisible: Bool) {
        guard isShieldActive else { return }
        lastRemaining = remaining
        lastUnlockVisible = unlockVisible
        let text = Format.mmss(remaining)
        for label in countdownLabels { label.stringValue = text }
        for button in unlockButtons { button.isHidden = !unlockVisible }
    }

    func hideRest() {
        guard isShieldActive else { return }
        isShieldActive = false
        activationTimer?.invalidate()
        activationTimer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        for window in restWindows { window.orderOut(nil) }
        restWindows = []
        countdownLabels = []
        unlockButtons = []
        NSApp.presentationOptions = savedPresentationOptions
    }

    // MARK: - 私有

    private func handleKeyDown(_ event: NSEvent) {
        guard event.keyCode == 53 else { return }   // ESC
        let now = Date()
        if now.timeIntervalSince(lastEscPressAt) <= 1.5 {
            escPressCount += 1
        } else {
            escPressCount = 1
        }
        lastEscPressAt = now
        if escPressCount >= 10 {   // ESC×10 紧急后门,任何配置下有效
            escPressCount = 0
            onUnlockRequested?()
        }
    }

    private func assertFrontmost() {
        NSApp.activate(ignoringOtherApps: true)
        for window in restWindows { window.orderFrontRegardless() }
        restWindows.first?.makeKey()
    }

    private func rebuildRestWindows() {
        guard isShieldActive else { return }
        for window in restWindows { window.orderOut(nil) }
        restWindows = []
        countdownLabels = []
        unlockButtons = []
        buildRestWindows()
        updateRest(remaining: lastRemaining, unlockVisible: lastUnlockVisible)
        assertFrontmost()
    }

    private func buildRestWindows() {
        for screen in NSScreen.screens {
            let window = makeRestWindow(for: screen)
            restWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    private func makeRestWindow(for screen: NSScreen) -> NSWindow {
        let window = KeyableWindow(contentRect: screen.frame,
                                   styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))

        let messageLabel = NSTextField(wrappingLabelWithString: config.message)
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 40, weight: .medium)
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messageLabel)

        let countdownLabel = NSTextField(labelWithString: "")
        countdownLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .regular)
        countdownLabel.alignment = .center
        countdownLabel.isHidden = !config.showCountdown
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(countdownLabel)
        countdownLabels.append(countdownLabel)

        let unlockButton = NSButton(title: "解锁", target: self, action: #selector(unlockClicked))
        unlockButton.isBordered = false
        unlockButton.wantsLayer = true
        unlockButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        unlockButton.layer?.cornerRadius = 8
        unlockButton.contentTintColor = .white
        unlockButton.font = .systemFont(ofSize: 15, weight: .medium)
        unlockButton.isHidden = true
        unlockButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(unlockButton)
        unlockButtons.append(unlockButton)

        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -20),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -40),
            countdownLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            countdownLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 24),
            unlockButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            unlockButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -30),
            unlockButton.widthAnchor.constraint(equalToConstant: 96),
            unlockButton.heightAnchor.constraint(equalToConstant: 40),
        ])

        window.contentView = content
        return window
    }

    @objc private func unlockClicked() {
        onUnlockRequested?()
    }
}

/// borderless 窗口默认拿不到键盘焦点,覆写以便吞键盘事件
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
