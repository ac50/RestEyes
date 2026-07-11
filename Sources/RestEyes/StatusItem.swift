import AppKit
import RestEyesCore

final class StatusItemController: NSObject {

    var onBreakNow: (() -> Void)?
    var onToggleSkipNext: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let countdownItem = NSMenuItem()
    private let skipItem = NSMenuItem()
    private let pauseItem = NSMenuItem()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "eye", accessibilityDescription: "RestEyes")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        countdownItem.title = "距下次休息 --:--"
        countdownItem.isEnabled = false
        menu.addItem(countdownItem)
        menu.addItem(.separator())

        menu.addItem(makeItem(title: "立即休息", action: #selector(breakNowClicked)))

        skipItem.title = "跳过下次休息"
        skipItem.target = self
        skipItem.action = #selector(skipClicked)
        menu.addItem(skipItem)

        pauseItem.title = "暂停 1 小时"
        pauseItem.target = self
        pauseItem.action = #selector(pauseClicked)
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        menu.addItem(makeItem(title: "打开配置文件", action: #selector(openConfigClicked)))
        menu.addItem(makeItem(title: "重新加载配置", action: #selector(reloadClicked)))
        menu.addItem(.separator())

        let quit = makeItem(title: "退出 RestEyes", action: #selector(quitClicked))
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func update(phase: Phase, remaining: TimeInterval, skipNextArmed: Bool) {
        switch phase {
        case .working:
            countdownItem.title = "距下次休息 \(Format.mmss(remaining))"
        case .warning:
            countdownItem.title = "即将休息…"
        case .resting:
            countdownItem.title = "休息中 \(Format.mmss(remaining))"
        case .paused:
            countdownItem.title = "已暂停(\(Format.mmss(remaining)) 后恢复)"
        }
        skipItem.state = skipNextArmed ? .on : .off
        pauseItem.title = phase == .paused ? "恢复计时" : "暂停 1 小时"
        skipItem.isEnabled = phase != .resting
        pauseItem.isEnabled = phase != .resting
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func breakNowClicked() { onBreakNow?() }
    @objc private func skipClicked() { onToggleSkipNext?() }
    @objc private func pauseClicked() { onPauseToggle?() }
    @objc private func openConfigClicked() { onOpenConfig?() }
    @objc private func reloadClicked() { onReloadConfig?() }
    @objc private func quitClicked() { onQuit?() }
}
