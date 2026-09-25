import Foundation

public struct GoldieConfig: Codable, Equatable {
    /// How often to re-read Cursor state.
    public var pollSeconds: Double = 10
    /// Threads with no activity for this long are ignored.
    public var activeWindowMinutes: Double = 20
    /// Threads active within this window count as "running in parallel".
    public var parallelWindowMinutes: Double = 3

    /// Rough size of turn 1 in a fresh thread (system prompt + rules + a short handoff).
    /// `contextRatio = context / freshBaselineTokens` is the core "start fresh" signal.
    public var freshBaselineTokens: Int = 15_000
    /// Added to *estimated* contexts to account for the system prompt/tools we can't see.
    public var systemOverheadTokens: Int = 8_000

    // Rule-brain bands (the LLM brain sees the raw numbers and may judge differently).
    public var heavyRatio: Double = 4
    public var alarmedRatio: Double = 8
    public var parallelAlarm: Int = 4

    public var speechCooldownMinutes: Double = 15
    public var snoozeMinutes: Double = 45
    /// Re-ask the LLM at least this often while agents are active, even if nothing changed.
    public var judgeIntervalMinutes: Double = 5

    public var llm: LLMConfig = LLMConfig()
    /// Opt-in prevention via Cursor's before-* hooks (Goldie offers these as suggestions).
    public var guards: GuardConfig = GuardConfig()
    /// Other AI tools that count toward the monthly budget.
    public var sources: SourcesConfig = SourcesConfig()

    /// Read your Cursor usage (per-request $) with your existing Cursor login. Read-only; the
    /// login token is only ever sent to cursor.com, exactly like the Cursor app does.
    public var cursorUsageAPI: Bool = true
    /// Monthly AI budget. Goldie's water level is the share of it that's left.
    public var monthlyBudgetUSD: Double = 800

    /// Policy: no models from Chinese vendors. Matched case-insensitively against model names.
    /// Goldie's own brain refuses to run on a match; Cursor chats using one get flagged.
    public var blockedModelKeywords: [String] = ModelPolicy.defaultBlockedKeywords
    public var usageRefreshMinutes: Double = 2
    /// A usage event is matched to the chat with agent activity closest in time, within this window.
    public var attributionToleranceSeconds: Double = 120

    /// Optional USD per 1M *input* tokens, keyed by a lowercase substring of the model name
    /// (e.g. "grok": <your price>). Key "default" applies to anything unmatched. Empty = no $ shown.
    public var inputPricePerMTok: [String: Double] = [:]
    /// Share of input served from prompt cache, and the price multiplier for cached tokens.
    public var cachedInputShare: Double = 0.8
    public var cachedInputDiscount: Double = 0.1

    public init() {}

    /// Loads ~/.config/goldie/config.json, deep-merged over defaults so partial files work.
    public static func load(from url: URL = Paths.configFile) -> GoldieConfig {
        let defaults = GoldieConfig()
        guard let data = try? Data(contentsOf: url),
              let user = J.obj(data) else { return defaults }
        return merged(defaults, with: user) ?? defaults
    }

    static func merged(_ base: GoldieConfig, with user: [String: Any]) -> GoldieConfig? {
        guard let baseData = try? JSONEncoder().encode(base),
              let baseObj = J.obj(baseData),
              let data = try? JSONSerialization.data(withJSONObject: deepMerge(baseObj, user)) else { return nil }
        return try? JSONDecoder().decode(GoldieConfig.self, from: data)
    }

    static func deepMerge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b {
            if let av = a[k] as? [String: Any], let bv = v as? [String: Any], k != "inputPricePerMTok" {
                out[k] = deepMerge(av, bv)
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// Writes the full config (used when you flip a toggle in Goldie).
    public func save(to url: URL = Paths.configFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    @discardableResult
    public static func writeDefaultIfMissing(to url: URL = Paths.configFile) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(GoldieConfig()) { try? data.write(to: url) }
        }
        return url
    }
}

public struct LLMConfig: Codable, Equatable {
    public var enabled: Bool = true
    /// Any OpenAI-compatible chat endpoint. Default: `mlx_lm.server` on this Mac.
    public var endpoint: String = "http://127.0.0.1:8080/v1/chat/completions"
    public var model: String = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    public var timeoutSeconds: Double = 30
    public init() {}
}

public enum ModelPolicy {
    /// Alibaba (Qwen/QwQ), DeepSeek, Zhipu (GLM), Baichuan, Shanghai AI Lab (InternLM), MiniMax,
    /// Moonshot (Kimi), Tencent (Hunyuan), Baidu (ERNIE), 01.AI (Yi), ByteDance (Doubao).
    public static let defaultBlockedKeywords = [
        "qwen", "qwq", "deepseek", "glm", "baichuan", "internlm", "minimax",
        "moonshot", "kimi", "hunyuan", "ernie", "01-ai", "/yi-", "doubao",
    ]

    /// The keyword that blocks this model, if any.
    public static func blockedKeyword(for model: String?, keywords: [String]) -> String? {
        guard let name = model?.lowercased(), !name.isEmpty else { return nil }
        return keywords.first { !$0.isEmpty && name.contains($0.lowercased()) }
    }
}

public struct GuardConfig: Codable, Equatable {
    /// Block an identical shell command once it has already run `loopRepeatLimit` times in one task
    /// with no file edited in between.
    public var loopGuard: Bool = false
    public var loopRepeatLimit: Int = 4
    /// Block reading files bigger than this (the agent may ask again to override).
    public var readGuard: Bool = false
    public var readLimitKB: Int = 256
    public init() {}
}

