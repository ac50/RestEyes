import Foundation

public enum UnlockAfter: Equatable {
    case seconds(Int)
    case never
}

public struct Config: Equatable {
    public var workMinutes: Double = 20
    public var restMinutes: Double = 3
    public var warnSeconds: Int = 10
    public var unlockAfter: UnlockAfter = .seconds(60)
    public var message: String = "休息一下,眺望远方 🌿"
    public var showCountdown: Bool = true
    public var lockAfterRest: Bool = true

    public init() {}

    public static let defaultFileContent = """
    # RestEyes 配置文件
    # 修改后在状态栏菜单点「重新加载配置」生效
    # 注意:# 起为注释,message 内容不能包含 #

    work_minutes = 20      # 工作时长(分钟,可用小数,如 0.5)
    rest_minutes = 3       # 休息时长(分钟,可用小数)
    warn_seconds = 10      # 黑屏前预警秒数,0 = 不预警直接黑屏
    unlock_after = 60      # 解锁按钮出现时机:秒数;0 = 一开始就显示;never = 永不显示
    message = 休息一下,眺望远方 🌿
    show_countdown = on    # 遮罩上是否显示剩余时间倒计时(on/off)
    lock_after_rest = on   # 休息自然结束后进入系统锁屏;手动解锁不触发(on/off)
    """

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/resteyes/config.txt")
    }

    public static func parse(_ text: String) -> Config {
        var c = Config()
        // Swift 将 "\r\n" 视为单个 grapheme cluster,与单独的 "\n" 不相等,
        // 直接 split(separator: "\n") 无法在 CRLF 处断行,需先归一化行尾。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "work_minutes":
                if let v = Double(value), v > 0, v <= 1440 { c.workMinutes = v }
            case "rest_minutes":
                if let v = Double(value), v > 0, v <= 1440 { c.restMinutes = v }
            case "warn_seconds":
                if let v = Int(value), (0...600).contains(v) { c.warnSeconds = v }
            case "unlock_after":
                if value == "never" {
                    c.unlockAfter = .never
                } else if let v = Int(value), (0...86400).contains(v) {
                    c.unlockAfter = .seconds(v)
                }
            case "message":
                c.message = value
            case "show_countdown":
                if value == "on" { c.showCountdown = true }
                else if value == "off" { c.showCountdown = false }
            case "lock_after_rest":
                if value == "on" { c.lockAfterRest = true }
                else if value == "off" { c.lockAfterRest = false }
            default:
                continue
            }
        }
        return c
    }

    public static func load(from url: URL = Config.defaultURL) -> Config {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? defaultFileContent.write(to: url, atomically: true, encoding: .utf8)
            return Config()
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Config()
        }
        return parse(text)
    }
}
