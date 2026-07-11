import Foundation

/// 系统锁屏:优先私有 API SACLockScreenImmediate(与 Ctrl+Cmd+Q 同源,无需 TCC 权限),
/// 符号不可用时降级为 CGSession -suspend(回到登录窗口,效果等价略重)。
enum ScreenLocker {

    static func lock() {
        if lockViaLoginFramework() { return }
        lockViaCGSession()
    }

    private static func lockViaLoginFramework() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) else {
            return false
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunc = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: LockFunc.self)()
        return true
    }

    private static func lockViaCGSession() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        process.arguments = ["-suspend"]
        try? process.run()
    }
}
