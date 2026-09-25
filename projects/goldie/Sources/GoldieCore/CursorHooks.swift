import Foundation

/// Adds/removes Goldie's entries in ~/.cursor/hooks.json without touching anyone else's hooks.
/// Only *observational* events are used, so a Goldie bug can never block a prompt, command or edit.
public enum CursorHooksInstaller {
    public static let events = ["afterAgentResponse", "afterShellExecution", "afterFileEdit", "afterMCPExecution", "stop"]
    static let marker = "goldiectl"

    /// `guards`: also register the before-shell/before-read hooks (only when a guard is turned on).
    public static func install(executable: String, guards: Bool = false, hooksFile: URL = Paths.cursorHooksFile) throws -> String {
        var root = try load(hooksFile)
        backupOnce(hooksFile)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events + Guards.events {
            var list = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            if events.contains(event) || guards {
                list.append(["command": "\"\(executable)\" hook \(event)"])
            }
            hooks[event] = list.isEmpty ? nil : list
        }
        root["hooks"] = hooks
        if root["version"] == nil { root["version"] = 1 }
        try save(root, to: hooksFile)
        return "Installed Goldie hooks for \(events.count) Cursor events in \(hooksFile.path). Restart Cursor to load them."
    }

    public static func uninstall(hooksFile: URL = Paths.cursorHooksFile) throws -> String {
        guard FileManager.default.fileExists(atPath: hooksFile.path) else { return "No \(hooksFile.path); nothing to remove." }
        var root = try load(hooksFile)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        try save(root, to: hooksFile)
        return "Removed Goldie hooks from \(hooksFile.path)."
    }

    static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) ?? false
    }

    static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return ["version": 1, "hooks": [String: Any]()] }
        let data = try Data(contentsOf: url)
        guard let obj = J.obj(data) else { throw GoldieError("\(url.path) isn't valid JSON; not touching it.") }
        return obj
    }

    static func save(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func backupOnce(_ url: URL) {
        let backup = url.appendingPathExtension("goldie-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
    }
}

/// `goldiectl probe`: prints the *shape* of your Cursor data (keys, types, token fields, tool names)
/// so we can verify the schema guesses. Never prints message text, file contents or commands.
public enum CursorProbe {
    public static func report(dbPath: String = Paths.cursorStateDB.path, hookFile: URL = Paths.hookEventsFile) -> String {
        var out: [String] = ["== Goldie probe (structure only: no message text, code or commands) =="]
        func say(_ s: String) { out.append(s) }

        say("\n# Cursor state DB\n\(dbPath)")
        if FileManager.default.fileExists(atPath: dbPath), let db = SQLiteReader(path: dbPath) {
            probeDB(db, dbPath: dbPath, say: say)
        } else {
            say("!! not found or can't be opened")
        }

        say("\n# Hook events\n\(hookFile.path)")
        if let text = try? String(contentsOf: hookFile, encoding: .utf8) {
            let lines = text.split(separator: "\n")
            say("lines: \(lines.count)")
            for line in lines.suffix(8) {
                guard let o = J.obj(String(line)) else { continue }
                let event = o["event"] as? String ?? "?"
                let keys = (o["keys"] as? [String])?.joined(separator: ",") ?? "?"
                let conv = (o["conversation_id"] as? String).map { String($0.prefix(8)) } ?? "-"
                say("  \(event)  conv=\(conv)  model=\(o["model"] as? String ?? "-")  payload keys=[\(keys)]")
            }
        } else {
            say("no events yet (install hooks with `goldiectl install-cursor-hooks`, restart Cursor, run an agent)")
        }
        return out.joined(separator: "\n")
    }

    private static func probeDB(_ db: SQLiteReader, dbPath: String, say: (String) -> Void) {
        let tables = db.strings("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.first ?? nil }
        say("tables: \(tables.joined(separator: ", "))")
        let range = "key >= 'composerData:' AND key < 'composerData;'"
        let count = db.strings("SELECT count(*) FROM cursorDiskKV WHERE \(range)").first?.first ?? nil
        say("composer threads: \(count ?? "?")")

        let cols = "substr(key, 14), rowid, json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'), length(value)"
        if tables.contains("composerHeaders") {
            let columns = db.strings("PRAGMA table_info(composerHeaders)").compactMap { $0.count > 2 ? "\($0[1] ?? "?"):\($0[2] ?? "?")" : nil }
            let headerCount = db.strings("SELECT count(*) FROM composerHeaders").first?.first ?? nil
            say("composerHeaders columns: \(columns.joined(separator: ", "))  rows: \(headerCount ?? "?")")
        }
        say("\nnewest by lastUpdatedAt (what Goldie watches):")
        let newest = db.strings("SELECT \(cols) FROM cursorDiskKV WHERE \(range) ORDER BY 3 DESC LIMIT 6")
        for r in newest {
            say("  \((r[0] ?? "?").prefix(8))  rowid=\(r[1] ?? "-")  lastUpdatedAt=\(r[2] ?? "-")  bytes=\(r[3] ?? "-")")
        }

        guard let id = newest.first?.first ?? nil,
              let data = db.firstValue("SELECT value FROM cursorDiskKV WHERE key = ?", ["composerData:\(id)"]),
              let composer = J.obj(data) else { return }

        say("\n# Newest composer \(id.prefix(8)): top-level fields")
        for key in composer.keys.sorted() {
            say("  \(key): \(describe(composer[key] ?? NSNull()))")
        }
        if let mc = composer["modelConfig"] as? [String: Any] {
            let pairs = mc.keys.sorted().map { key in "\(key)=\(mc[key] ?? "nil")" }
            say("modelConfig: " + pairs.joined(separator: "  "))
        }

        let prefix = "bubbleId:\(id):"
        let rows = db.rows("SELECT value FROM cursorDiskKV WHERE key >= ? AND key < ?", [prefix, "bubbleId:\(id);"])
        say("\n# Its bubbles: \(rows.count) rows")
        var keyCounts: [String: Int] = [:]
        var toolKeys: [String: Int] = [:]
        var argKeys: [String: Int] = [:]
        var toolNames: [String: Int] = [:]
        var tokenSamples: [String] = []
        for row in rows {
            guard let d = row.first ?? nil, let b = J.obj(d) else { continue }
            for k in b.keys { keyCounts[k, default: 0] += 1 }
            if let tc = b["tokenCount"] as? [String: Any] {
                tokenSamples.append("type\(J.int(b["type"]) ?? -1):" + tc.keys.sorted().map { "\($0)=\(J.int(tc[$0]) ?? -1)" }.joined(separator: ","))
            }
            if let tool = b["toolFormerData"] as? [String: Any] {
                for k in tool.keys { toolKeys[k, default: 0] += 1 }
                if let name = tool["name"] as? String { toolNames[name, default: 0] += 1 }
                if let raw = tool["rawArgs"] as? String, let args = J.obj(raw) {
                    for k in args.keys { argKeys[k, default: 0] += 1 }
                }
            }
        }
        func fmt(_ d: [String: Int]) -> String { d.sorted { $0.value > $1.value }.map { "\($0.key)(\($0.value))" }.joined(separator: " ") }
        say("bubble fields: \(fmt(keyCounts))")
        say("toolFormerData fields: \(fmt(toolKeys))")
        say("tool names: \(fmt(toolNames))")
        say("tool arg keys: \(fmt(argKeys))")
        say("tokenCount samples (last 10): \(tokenSamples.suffix(10).joined(separator: " | "))")

        if let thread = CursorStore(path: dbPath).loadThread(id: id) {
            let snap = Signals.build(id: id, thread: thread, hook: nil, config: GoldieConfig(), now: Date())
            say("\n# What Goldie derives for it")
            say("  messages=\(snap.messages) userTurns=\(snap.userTurns) model=\(snap.model ?? "-") maxMode=\(snap.maxMode)")
            say("  context=\(snap.contextTokens) tokens (source: \(snap.contextSource)), ratio=\(String(format: "%.1f", snap.contextRatio))")
            say("  toolCallsSinceUser=\(snap.toolCallsSinceUser) repeatCmd=\(snap.maxRepeatCommand) repeatFile=\(snap.maxRepeatFileEdit) loop=\(String(format: "%.2f", snap.loopScore))")
        }
    }

    static func describe(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber { return "number(\(n))" }
        if let s = v as? String { return "string(len \(s.count))" }
        if let a = v as? [Any] { return "array(\(a.count))" }
        if let d = v as? [String: Any] {
            // Key names only when they look like field names; keys can be file paths or URLs.
            let keys = d.keys.sorted()
            let safe = keys.allSatisfy { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,40}$", options: .regularExpression) != nil }
            return safe ? "object{\(keys.prefix(15).joined(separator: ","))}" : "object(\(d.count) keys, names hidden)"
        }
        return "\(type(of: v))"
    }
}
