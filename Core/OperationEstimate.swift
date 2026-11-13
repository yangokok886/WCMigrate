import Foundation
public struct OperationEstimate {
    private var samples: [(date: Date, fraction: Double)] = []
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
        guard let raw = progress.fraction, raw.isFinite else { reset(); return }
        let value = min(1, max(fraction ?? 0, raw))
        fraction = value
        guard value < 1 else { remaining = nil; samples = []; return }
        // Keep a recent window: an initial large file must not determine the estimate
        // for tens of thousands of small files that follow (or the other way around).
        if let last = samples.last, now.timeIntervalSince(last.date) < 0.2 { return }
        samples.append((now, value))
        while samples.count > 2 && now.timeIntervalSince(samples[1].date) > 30 { samples.removeFirst() }
        guard let first = samples.first else { return }
        let elapsed = now.timeIntervalSince(first.date)
        let made = value - first.fraction
        guard elapsed >= 3, made > 0.005 else { remaining = nil; return }
        let estimate = min(7 * 86400, elapsed / made * (1 - value))
        if let old = remaining { remaining = old * 0.8 + estimate * 0.2 }
        else { remaining = estimate }
    }
}
