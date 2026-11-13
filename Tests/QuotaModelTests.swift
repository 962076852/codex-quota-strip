import Foundation

@main struct QuotaModelTests {
    static func main() {
        let weekly: [String: Any] = ["windowDurationMins": 10080.0, "resetsAt": 2000000000.0, "usedPercent": 72.0]
        let short: [String: Any] = ["windowDurationMins": 300.0, "resetsAt": 1900000000.0, "usedPercent": 10.0]
        let primary: [String: Any] = ["rateLimits": ["limitId": "codex", "primary": weekly]]
        let secondary: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": short, "secondary": weekly]]]
        precondition(WeeklyQuota.parse(primary)?.remainingPercent == 28)
        precondition(WeeklyQuota.parse(secondary)?.resetsAt == 2000000000)
        precondition(WeeklyQuota.parse(["rateLimits": ["primary": short]]) == nil)
        precondition(WeeklyQuota.parse(["rateLimitsByLimitId": ["model_specific": ["primary": weekly]], "rateLimits": ["primary": weekly]]) == nil)
        precondition(WeeklyQuota.parse(["rateLimits": ["primary": ["windowDurationMins": 10080.0, "usedPercent": 0.0]]]) == nil)
        precondition(RemainingLevel.classify(21) == .normal)
        precondition(RemainingLevel.classify(20) == .warning)
        precondition(RemainingLevel.classify(6) == .warning)
        precondition(RemainingLevel.classify(5) == .critical)
        precondition(RemainingLevel.classify(0) == .critical)
        print("PASS: weekly windows, unavailable data, model isolation and warning thresholds")
    }
}
