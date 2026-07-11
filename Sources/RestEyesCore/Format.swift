import Foundation

public enum Format {
    /// 秒 → "m:ss",负数归零
    public static func mmss(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
