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

    func update(phase: Phase, remaining: TimeInterval, skipNextArmed: Bool,
                skipsExhausted: Bool) {
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

        // suffix 只在计数是真实致灰原因时才挂:resting 中置灰的原因是「休息中」,与计数无关,
        // 此时说「请先完成一次休息」会误导(它马上就要休息完了)。
        let suffix = (skipsExhausted && phase != .resting) ? "(已达连续上限,请先完成一次休息)" : ""

        if phase == .paused {
            pauseItem.title = "恢复计时"
            pauseItem.isEnabled = true          // 恢复永不被计数禁用,否则会被锁死在暂停里
        } else {
            pauseItem.title = "暂停 1 小时\(suffix)"
            pauseItem.isEnabled = phase != .resting && !skipsExhausted
        }

        skipItem.state = skipNextArmed ? .on : .off
        skipItem.title = "跳过下次休息\(suffix)"
        // armed 时保持可点,否则用户无法取消一个已经不会生效的勾选
        skipItem.isEnabled = phase != .resting && (!skipsExhausted || skipNextArmed)
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
