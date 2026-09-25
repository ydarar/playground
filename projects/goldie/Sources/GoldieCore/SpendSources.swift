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

    /// The gateway virtual key: env var first, then the Keychain. Never logged or stored by Goldie.
    public static func key() -> String? {
        if let env = ProcessInfo.processInfo.environment["GOLDIE_LLMG_KEY"], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spend for this key from LiteLLM's `/key/info` (`info.spend`, else top-level `spend`).
    public static func spend(baseURL: String, key: String) async throws -> Double {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + "/key/info") else { throw GoldieError("bad claudeGatewayURL") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let body = J.obj(data) else { throw GoldieError("gateway returned HTTP \(status)") }
        let info = body["info"] as? [String: Any] ?? [:]
        guard let spend = J.number(info["spend"]) ?? J.number(body["spend"]) else { throw GoldieError("no spend in /key/info") }
        return spend
    }

    /// Status text for the budget row when Claude isn't connected yet.
    public static func setupHint(config: SourcesConfig) -> String? {
        if config.claudeGatewayURL.isEmpty { return "add sources.claudeGatewayURL in config" }
        if key() == nil { return "add your gateway key to the Keychain (service goldie-llmg)" }
        return nil
    }
}
