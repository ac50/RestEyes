import Foundation
import ServiceManagement

/// 开机自启:仅在配置值发生变化时调用 SMAppService 注册/注销。
/// SMAppService.status 无法区分"从未注册"与"用户在系统设置里手动关闭",
/// 按状态对账会把用户手动关掉的开关翻回来;因此用 UserDefaults 记录上次
/// 应用的值,稳态启动不做任何 SMAppService 调用,尊重用户的手动选择。
enum LoginItem {

    private static let appliedKey = "LaunchAtLoginApplied"

    static func sync(enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // 裸二进制(开发场景)跳过
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: appliedKey) as? Bool, last == enabled {
            return   // 配置未变,不打扰系统状态
        }
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        defaults.set(enabled, forKey: appliedKey)
    }
}
