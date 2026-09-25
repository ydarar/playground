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
    /// UTF-8 length of the tool's result only (file contents, command output).
    public var resultLength: Int = 0
    public var resultIsImage: Bool = false
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
    /// Sub-task chats this chat spawned (Cursor's task tool).
    public var subagentIds: [String] = []
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

    private var recentCache: (at: Date, refs: [ComposerRef])?
    private var headersAvailable: Bool?
    private var subagentCache: (at: Date, ids: Set<String>)?

    /// Cursor 3.x keeps a small `composerHeaders` table (id, lastUpdatedAt, isSubagent, isArchived…).
    /// Reading it is far cheaper than JSON-parsing every chat.
    private func hasHeaders(_ db: SQLiteReader) -> Bool {
        if let known = headersAvailable { return known }
        let found = !db.strings("SELECT name FROM sqlite_master WHERE type='table' AND name='composerHeaders'").isEmpty
        headersAvailable = found
        return found
    }

    /// Most recently updated top-level chats (no sub-task chats, no archived ones).
    public func recentComposers(limit: Int, now: Date = Date(), maxAge: TimeInterval = 60) -> [ComposerRef] {
        guard let db = open() else { return [] }
        if hasHeaders(db) {
            let rows = db.strings("SELECT composerId, lastUpdatedAt FROM composerHeaders WHERE IFNULL(isArchived, 0) = 0 AND IFNULL(isSubagent, 0) = 0 ORDER BY lastUpdatedAt DESC LIMIT \(limit)")
            return rows.compactMap { row -> ComposerRef? in
                guard row.count == 2, let id = row[0], let raw = row[1], let updated = J.date(Double(raw)) else { return nil }
                return ComposerRef(id: id, updated: updated, signature: "")
            }
        }
        // Older Cursor: JSON-parse every composer, so cache the list for a minute (hooks cover real time).
        if let cached = recentCache, now.timeIntervalSince(cached.at) < maxAge { return cached.refs }
        let rows = db.strings("SELECT key, json_extract(CAST(value AS TEXT), '$.lastUpdatedAt') FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;' ORDER BY 2 DESC LIMIT \(limit)")
        let refs = rows.compactMap { row -> ComposerRef? in
            guard row.count == 2, let key = row[0], let raw = row[1], let updated = J.date(Double(raw)) else { return nil }
            return ComposerRef(id: String(key.dropFirst("composerData:".count)), updated: updated, signature: "")
        }
        recentCache = (at: now, refs: refs)
        return refs
    }

    /// Sub-task chats, so they aren't shown as separate chats (their cost rolls up to the parent).
    public func subagentIDs(now: Date = Date()) -> Set<String> {
        if let cached = subagentCache, now.timeIntervalSince(cached.at) < 60 { return cached.ids }
        guard let db = open(), hasHeaders(db) else { return [] }
        let ids = Set(db.strings("SELECT composerId FROM composerHeaders WHERE isSubagent = 1").compactMap { $0.first ?? nil })
        subagentCache = (at: now, ids: ids)
        return ids
    }

    /// Changes whenever the chat changes. Uses the headers table when present (no JSON parsing).
    public func signature(id: String) -> String? {
        guard let db = open() else { return nil }
        if hasHeaders(db) {
            let updated = db.strings("SELECT lastUpdatedAt FROM composerHeaders WHERE composerId = ?", [id]).first?.first ?? nil
            let length = db.strings("SELECT length(value) FROM cursorDiskKV WHERE key = ?", ["composerData:\(id)"]).first?.first ?? nil
            guard updated != nil || length != nil else { return nil }
            return "\(updated ?? "-")/\(length ?? "-")"
        }
        guard let row = db.strings("SELECT json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'), length(value) FROM cursorDiskKV WHERE key = ?", ["composerData:\(id)"]).first,
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
            bubbles: bubbles,
            subagentIds: (composer["subagentComposerIds"] as? [String]) ?? []
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
        var resultLength = 0
        var resultHead = ""
        if let r = tool["result"] as? String {
            resultLength = r.utf8.count
            resultHead = String(r.prefix(400)).lowercased()
        } else if let r = tool["result"], JSONSerialization.isValidJSONObject(r),
                  let data = try? JSONSerialization.data(withJSONObject: r) {
            resultLength = data.count
            resultHead = String(decoding: data.prefix(400), as: UTF8.self).lowercased()
        }
        let lowerTool = (toolName ?? "").lowercased()
        // Screenshots/images aren't the "huge file or log" problem the big-read signal is about.
        let resultIsImage = lowerTool.contains("screenshot") || lowerTool.contains("image")
            || resultHead.contains("data:image") || resultHead.contains("base64") || resultHead.contains("\"image\"")
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
            textLength: J.textLength(b),
            resultLength: resultLength,
            resultIsImage: resultIsImage
        )
    }
}
