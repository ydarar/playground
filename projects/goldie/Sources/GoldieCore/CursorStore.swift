import Foundation

/// One message ("bubble") in a Cursor composer thread, reduced to what Goldie needs.
public struct CursorBubble: Equatable {
    public var isUser: Bool
    public var isTool: Bool
    public var isEdit: Bool
    public var text: String
    public var toolName: String?
    public var command: String?
    public var filePath: String?
    /// `tokenCount.inputTokens` if Cursor recorded it (may be absent or 0 depending on version).
    public var inputTokens: Int?
    public var createdAt: Date?
    /// UTF-8 length of all text in the bubble (message, tool args, tool results).
    public var textLength: Int
}

public struct CursorThread: Equatable {
    public var id: String
    public var title: String
    public var model: String?
    public var maxMode: Bool
    public var createdAt: Date?
    public var lastUpdatedAt: Date?
    /// Context size if Cursor stores it on the composer (field names vary by version).
    public var reportedContextTokens: Int?
    public var bubbles: [CursorBubble]
}

/// Reads Cursor agent ("composer") threads from Cursor's local state DB.
///
/// Layout (as of Cursor 1.x/2.x, verify with `goldiectl probe`):
/// - `cursorDiskKV["composerData:<id>"]`  → thread JSON: name, timestamps, modelConfig,
///   `fullConversationHeadersOnly` (ordered bubble ids) or, in older builds, inline `conversation`.
/// - `cursorDiskKV["bubbleId:<id>:<bubbleId>"]` → one message: type (1 user / 2 assistant), text,
///   tokenCount, toolFormerData (tool name, rawArgs, result).
public final class CursorStore {
    public let path: String
    private var db: SQLiteReader?

    /// Parsed bubbles per composer, keyed by bubble id, with the row length they were parsed at.
    /// Long threads have thousands of bubbles; only new or changed rows are re-read and re-parsed.
    private var bubbleCache: [String: [String: (length: Int, bubble: CursorBubble)]] = [:]

    public init(path: String = Paths.cursorStateDB.path) {
        self.path = path
    }

    /// Drop cached bubbles for threads that are no longer being watched.
    public func retainCache(for ids: Set<String>) {
        bubbleCache = bubbleCache.filter { ids.contains($0.key) }
    }

    private func loadBubbles(db: SQLiteReader, composerID id: String) -> [String: CursorBubble] {
        let prefix = "bubbleId:\(id):"
        let lengths = db.strings("SELECT key, length(value) FROM cursorDiskKV WHERE key >= ? AND key < ?", [prefix, "bubbleId:\(id);"])
        var cache = bubbleCache[id] ?? [:]
        var current: [String: Int] = [:]
        var stale: [String] = []
        for row in lengths {
            guard row.count == 2, let key = row[0], let length = row[1].flatMap({ Int($0) }) else { continue }
            let bid = String(key.dropFirst(prefix.count))
            current[bid] = length
            if cache[bid]?.length != length { stale.append(bid) }
        }
        var start = 0
        while start < stale.count {
            let chunk = Array(stale[start..<min(start + 200, stale.count)])
            start += 200
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = db.rows("SELECT key, value FROM cursorDiskKV WHERE key IN (\(placeholders))", chunk.map { prefix + $0 })
            for row in rows {
                guard row.count == 2, let key = J.string(row[0]), let raw = row[1].flatMap({ J.obj($0) }) else { continue }
                let bid = String(key.dropFirst(prefix.count))
                cache[bid] = (length: current[bid] ?? 0, bubble: CursorStore.parseBubble(raw))
            }
        }
        cache = cache.filter { current[$0.key] != nil }
        bubbleCache[id] = cache
        return cache.mapValues { $0.bubble }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    private func open() -> SQLiteReader? {
        if db == nil, exists { db = SQLiteReader(path: path) }
        return db
    }

    public struct ComposerRef {
        public var id: String
        public var updated: Date?
        /// Changes whenever the composer row changes; used to skip re-parsing.
        public var signature: String
    }

    /// Most recently written composers. Rows are upserted with REPLACE, so the highest rowids are
    /// the most recently touched; that avoids JSON-parsing every thread on every poll.
    public func recentComposers(limit: Int) -> [ComposerRef] {
        guard let db = open() else { return [] }
        let select = "SELECT key, json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'), length(value) FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;'"
        var rows = db.strings(select + " ORDER BY rowid DESC LIMIT \(limit)")
        if rows.isEmpty {
            rows = db.strings(select + " ORDER BY 2 DESC LIMIT \(limit)")
        }
        return rows.compactMap { row in
            guard row.count == 3, let key = row[0] else { return nil }
            let id = String(key.dropFirst("composerData:".count))
            let updated = J.date(row[1].flatMap { Double($0) })
            return ComposerRef(id: id, updated: updated, signature: "\(row[1] ?? "-")/\(row[2] ?? "-")")
        }
    }

    public func signature(id: String) -> String? {
        guard let db = open(),
              let row = db.strings("SELECT json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'), length(value) FROM cursorDiskKV WHERE key = ?", ["composerData:\(id)"]).first,
              row.count == 2 else { return nil }
        return "\(row[0] ?? "-")/\(row[1] ?? "-")"
    }

    public func loadThread(id: String) -> CursorThread? {
        guard let db = open(),
              let data = db.firstValue("SELECT value FROM cursorDiskKV WHERE key = ?", ["composerData:\(id)"]),
              let composer = J.obj(data) else { return nil }

        var bubbles: [CursorBubble] = []
        if let inline = composer["conversation"] as? [[String: Any]], !inline.isEmpty {
            bubbles = inline.map(CursorStore.parseBubble)
        } else {
            let byID = loadBubbles(db: db, composerID: id)
            let headers = composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? []
            if headers.isEmpty {
                bubbles = byID.values
                    .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            } else {
                bubbles = headers.compactMap { header -> CursorBubble? in
                    guard let bid = header["bubbleId"] as? String else { return nil }
                    return byID[bid]
                }
            }
        }

        let modelConfig = composer["modelConfig"] as? [String: Any] ?? [:]
        return CursorThread(
            id: id,
            title: (composer["name"] as? String) ?? "",
            model: (modelConfig["modelName"] as? String) ?? (composer["model"] as? String),
            maxMode: (modelConfig["maxMode"] as? Bool) ?? false,
            createdAt: J.date(composer["createdAt"]),
            lastUpdatedAt: J.date(composer["lastUpdatedAt"]),
            reportedContextTokens: CursorStore.reportedContext(composer),
            bubbles: bubbles
        )
    }

    static func reportedContext(_ composer: [String: Any]) -> Int? {
        if let n = J.firstNumber(composer, ["contextTokensUsed", "contextTokenCount", "contextUsedTokens", "usedContextTokens"]), n > 0 {
            return Int(n)
        }
        if let pct = J.number(composer["contextUsagePercent"]), let limit = J.number(composer["contextTokenLimit"]), pct > 0, limit > 0 {
            return Int(pct / 100 * limit)
        }
        return nil
    }

    static let fileArgKeys = ["target_file", "file_path", "relative_workspace_path", "targetFile", "path", "filePath"]
    static let editWords = ["edit", "write", "replace", "patch", "apply", "create", "delete"]

    static func parseBubble(_ b: [String: Any]) -> CursorBubble {
        let type = J.int(b["type"]) ?? 0
        let tool = b["toolFormerData"] as? [String: Any] ?? [:]
        let toolName = (tool["name"] as? String) ?? (tool["tool"] as? String)

        var args: [String: Any] = [:]
        if let raw = tool["rawArgs"] as? String, let parsed = J.obj(raw) {
            args = parsed
        } else if let params = tool["params"] as? [String: Any] {
            args = params
        } else if let params = tool["params"] as? String, let parsed = J.obj(params) {
            args = parsed
        }

        let isTool = toolName != nil || !args.isEmpty
        let lowerName = (toolName ?? "").lowercased()
        let tokenCount = b["tokenCount"] as? [String: Any] ?? [:]

        return CursorBubble(
            isUser: type == 1,
            isTool: isTool,
            isEdit: isTool && editWords.contains { lowerName.contains($0) },
            text: (b["text"] as? String) ?? "",
            toolName: toolName,
            command: args["command"] as? String,
            filePath: fileArgKeys.lazy.compactMap { args[$0] as? String }.first,
            inputTokens: J.int(tokenCount["inputTokens"]),
            createdAt: J.date(b["createdAt"]),
            textLength: J.textLength(b)
        )
    }
}
