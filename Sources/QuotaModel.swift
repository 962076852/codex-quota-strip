import Foundation

struct WeeklyQuota {
    let resetsAt: Double
    let remainingPercent: Double

    static func parse(_ result: [String: Any]) -> WeeklyQuota? {
        let bucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            bucket = buckets["codex"] as? [String: Any]
        } else {
            bucket = result["rateLimits"] as? [String: Any]
        }
        guard let bucket = bucket,
              bucket["limitId"] == nil || bucket["limitId"] as? String == "codex" else { return nil }
        let windows = [bucket["primary"], bucket["secondary"]].compactMap { $0 as? [String: Any] }
        guard let weekly = windows.first(where: {
            guard let minutes = $0["windowDurationMins"] as? Double else { return false }
            return abs(minutes - 10080) <= 1
        }), let reset = weekly["resetsAt"] as? Double,
            let used = weekly["usedPercent"] as? Double,
            reset.isFinite, used.isFinite, reset > 0 else { return nil }
        return WeeklyQuota(resetsAt: reset, remainingPercent: max(0, min(100, 100 - used)))
    }
}

enum RemainingLevel: String {
    case normal, warning, critical
    static func classify(_ remaining: Double) -> RemainingLevel {
        let displayed = Int(max(0, min(100, remaining)).rounded())
        if displayed <= 5 { return .critical }
        return displayed <= 20 ? .warning : .normal
    }
}
