import Foundation
import Security

/// Every AI tool that counts toward the one monthly AI token budget.
public enum SpendSourceID: String, CaseIterable, Codable {
    case cursor, claude, codex, opencode

    public var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

public struct SourceSpend: Equatable, Identifiable {
    public var id: SpendSourceID
    /// Month-to-date $, nil when not connected.
    public var monthUSD: Double?
    /// "connected", "manual", or why it isn't connected.
    public var status: String

    public init(id: SpendSourceID, monthUSD: Double?, status: String) {
        self.id = id
        self.monthUSD = monthUSD
        self.status = status
    }
}

public struct SourcesConfig: Codable, Equatable {
    /// Claude: your LLM gateway (LiteLLM) base URL, e.g. "https://<gateway-host>". Goldie calls
    /// `GET /key/info` with your virtual key. The key comes from the Keychain
    /// (`security add-generic-password -s goldie-llmg -a llmg -w '<key>'`) or env `GOLDIE_LLMG_KEY`.
    public var claudeGatewayURL: String = ""
    /// Month-to-date $ for tools without an API hookup yet. Update now and then; nil = not counted.
    public var codexMonthUSD: Double? = nil
    public var opencodeMonthUSD: Double? = nil
    public init() {}
}

public enum ClaudeGateway {
    public static let keychainService = "goldie-llmg"

    public enum KeyLookup: Equatable {
        case found(String)
        case missing
        /// The Keychain item exists but Goldie wasn't allowed to read it.
        case denied
    }

    /// The gateway virtual key: env var first, then the Keychain. Never logged or stored by Goldie.
    /// Call off the main thread: the Keychain may show an access prompt.
    public static func lookupKey() -> KeyLookup {
        if let env = ProcessInfo.processInfo.environment["GOLDIE_LLMG_KEY"], !env.isEmpty { return .found(env) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return .missing }
            return .found(key.trimmingCharacters(in: .whitespacesAndNewlines))
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .missing
        }
    }

    public struct Spend: Equatable {
        public var usd: Double
        /// True when the key has a budget period (e.g. monthly), so `usd` resets each period.
        /// False means LiteLLM reports the key's lifetime spend.
        public var isPeriod: Bool
        public var resetsAt: String?
    }

    /// Spend for this key from LiteLLM's `/key/info` (`info.spend`, else top-level `spend`).
    public static func spend(baseURL: String, key: String) async throws -> Spend {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + "/key/info") else { throw GoldieError("bad claudeGatewayURL") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let body = J.obj(data) else { throw GoldieError("gateway returned HTTP \(status)") }
        let info = body["info"] as? [String: Any] ?? body
        guard let usd = J.number(info["spend"]) ?? J.number(body["spend"]) else { throw GoldieError("no spend in /key/info") }
        let duration = (info["budget_duration"] as? String) ?? ""
        return Spend(usd: usd, isPeriod: !duration.isEmpty, resetsAt: info["budget_reset_at"] as? String)
    }

    /// Month-to-date from a lifetime total: the difference from the first reading seen this month
    /// (persisted), so Goldie never counts earlier months against this month's budget.
    public static func monthToDate(lifetime: Double, now: Date, defaults: UserDefaults = .standard) -> (usd: Double, since: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        let key = "goldie.claude.baseline." + f.string(from: now)
        let sinceKey = key + ".since"
        if defaults.object(forKey: key) == nil {
            defaults.set(lifetime, forKey: key)
            defaults.set(now.timeIntervalSince1970, forKey: sinceKey)
        }
        let baseline = defaults.double(forKey: key)
        let since = Date(timeIntervalSince1970: defaults.double(forKey: sinceKey))
        return (max(0, lifetime - baseline), since)
    }

    public static let keyHelp = "store it with: security add-generic-password -s goldie-llmg -a llmg -w '<key>' -T <path to .build/release/Goldie> (or set GOLDIE_LLMG_KEY)"
}
