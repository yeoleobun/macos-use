import Foundation

/// Guardrail policy enforcing destructive-action confirmation gates and per-minute action rate limits.
public actor SafetyPolicyManager {
    public static let shared = SafetyPolicyManager()

    private var mode: String = "standard" // "standard" | "strict" | "permissive"
    private var maxActionsPerMinute: Int = 180
    private var actionTimestamps: [ContinuousClock.Instant] = []

    private let highRiskPatterns: [String] = [
        "empty trash",
        "清倒废纸篓",
        "erase all",
        "erase disk",
        "format disk",
        "factory reset",
        "delete account",
        "permanently delete",
        "永久删除",
        "confirm payment",
        "pay now",
        "complete purchase",
        "wire transfer"
    ]

    private let strictPatterns: [String] = [
        "delete",
        "remove",
        "trash",
        "send",
        "pay",
        "删除",
        "清空",
        "发送",
        "付款"
    ]

    private let standardSafeWhitelist: [String] = [
        "end call",
        "hangup",
        "close",
        "minimize",
        "zoom",
        "cancel",
        "clear",
        "quit"
    ]

    public init() {}

    public func currentConfig() -> SafetyPolicyConfig {
        SafetyPolicyConfig(
            mode: mode,
            maxActionsPerMinute: maxActionsPerMinute,
            destructivePatternsCount: highRiskPatterns.count
        )
    }

    public func configure(mode: String? = nil, maxActionsPerMinute: Int? = nil) throws -> SafetyPolicyConfig {
        if let mode {
            let norm = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["standard", "strict", "permissive"].contains(norm) else {
                throw MacOSUseError.invalidArgument("Unsupported policy_mode '\(mode)'. Expected standard, strict, or permissive.")
            }
            self.mode = norm
        }
        if let limit = maxActionsPerMinute {
            guard limit >= 10 && limit <= 2000 else {
                throw MacOSUseError.invalidArgument("max_actions_per_minute must be between 10 and 2000.")
            }
            self.maxActionsPerMinute = limit
        }
        return currentConfig()
    }

    public func checkAction(
        tool: String,
        targetLabel: String?,
        menuPath: [String]? = nil,
        confirmDestructive: Bool = false
    ) throws {
        let mutatingTools: Set<String> = [
            "click", "drag", "type_text", "press_key", "menu_action", "widget_action", "handle_dialog"
        ]
        if mutatingTools.contains(tool) {
            let now = ContinuousClock.now
            let windowStart = now - .seconds(60)
            actionTimestamps.removeAll { $0 < windowStart }
            if actionTimestamps.count >= maxActionsPerMinute {
                throw MacOSUseError.safetyBlocked(
                    "Rate limit exceeded (\(maxActionsPerMinute) mutating actions/min). Adjust via session_trace(action='set_policy') if intended."
                )
            }
            actionTimestamps.append(now)
        }

        guard mode != "permissive", !confirmDestructive else {
            return
        }

        let candidateText = ([targetLabel] + (menuPath ?? []).map(Optional.some))
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !candidateText.isEmpty else { return }

        if mode == "standard", standardSafeWhitelist.contains(where: { candidateText.contains($0) }) {
            return
        }

        for pattern in highRiskPatterns {
            if candidateText.contains(pattern) {
                throw MacOSUseError.safetyBlocked(
                    "High-risk target '\(candidateText)' matched destructive guard '\(pattern)'. Pass confirm_destructive=true to authorize."
                )
            }
        }

        if mode == "strict" {
            for pattern in strictPatterns {
                if candidateText.contains(pattern) {
                    throw MacOSUseError.safetyBlocked(
                        "Strict policy blocked target '\(candidateText)' matching '\(pattern)'. Pass confirm_destructive=true to authorize."
                    )
                }
            }
        }
    }
}
