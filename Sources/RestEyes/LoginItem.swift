import Foundation
import ServiceManagement

/// 开机自启:用 SMAppService.mainApp 注册/注销,启动与配置重载时与配置对账。
/// 用户在「系统设置 → 登录项」手动关闭后,系统保留用户选择,这里的注册尝试不会强行翻转。
enum LoginItem {

    static func sync(enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // 裸二进制(开发场景)跳过
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try? service.register()
        } else {
            guard service.status == .enabled else { return }
            try? service.unregister()
        }
    }
}
