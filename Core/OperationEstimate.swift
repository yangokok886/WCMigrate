import Foundation
public struct OperationEstimate {
    private var start: Date?
    private var lastFraction: Double = 0
    public private(set) var fraction: Double?
    public private(set) var remaining: TimeInterval?
    public init() {}
    public static func timeText(_ seconds: TimeInterval) -> String {
        let value = max(1, Int(ceil(seconds)))
        if value >= 3600 { return "\(value / 3600)小时\((value % 3600) / 60)分" }
        if value >= 60 { return "\(value / 60)分\(value % 60)秒" }
        return "\(value)秒"
    }
    public mutating func reset() { self = OperationEstimate() }
    public mutating func update(_ progress: BackupProgress, now: Date = Date()) {
        guard let raw = progress.fraction else { fraction = nil; remaining = nil; start = nil; lastFraction = 0; return }
        let value = min(1, max(0, raw))
        if start == nil { start = now; lastFraction = value; fraction = value; remaining = nil; return }
        fraction = max(fraction ?? 0, value)
        let elapsed = now.timeIntervalSince(start!)
        let made = value - lastFraction
        remaining = elapsed >= 3 && made > 0.005 && value < 1 ? min(7 * 86400, elapsed / made * (1 - value)) : nil
    }
}
