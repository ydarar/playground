import Foundation

/// Live per-conversation state derived from Cursor agent hooks.
public struct HookThreadState: Equatable {
    public var lastEventAt: Date
    public var running: Bool = false
    public var lastStatus: String?
    public var model: String?
    public var workspace: String?
    /// Stats for the current (or most recent) agent run, i.e. since the previous `stop`.
    public var runToolEvents: Int = 0
    public var runCommands: [String: Int] = [:]
    public var runFiles: [String: Int] = [:]
    /// Timestamps of recent agent activity; used to match Cursor usage events (and their $) to this thread.
    public var recentEventTimes: [Date] = []
    /// Times a Goldie guard blocked a step in this conversation.
    public var guardBlocks: Int = 0

    public init(lastEventAt: Date) { self.lastEventAt = lastEventAt }
}

/// Tails the JSONL file that `goldiectl hook` appends to.
public final class HookTracker {
    public private(set) var threads: [String: HookThreadState] = [:]
    public private(set) var hasSeenEvents = false

    private let file: URL
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var skipPartialLine = false
    private let maxInitialBytes: UInt64 = 2_000_000

    public init(file: URL = Paths.hookEventsFile) {
        self.file = file
    }

    public func poll(now: Date = Date()) {
        defer { prune(now: now) }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {  // file was truncated/rotated
            offset = 0
            remainder = Data()
        }
        if offset == 0 && size > maxInitialBytes {  // on startup only replay the tail
            offset = size - maxInitialBytes
            skipPartialLine = true
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        ingest(data)
    }

    func ingest(_ data: Data) {
        var buffer = remainder + data
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer = buffer.subdata(in: (newline + 1)..<buffer.endIndex)
        }
        remainder = buffer
        if skipPartialLine, !lines.isEmpty {
            lines.removeFirst()
            skipPartialLine = false
        }
        for line in lines {
            if let obj = J.obj(line) { apply(obj) }
        }
    }

    func apply(_ o: [String: Any]) {
        hasSeenEvents = true
        let id = (o["conversation_id"] as? String) ?? "unknown"
        let ts = J.date(o["ts"]) ?? Date()
        let event = (o["event"] as? String) ?? ""
        var s = threads[id] ?? HookThreadState(lastEventAt: ts)
        s.lastEventAt = max(s.lastEventAt, ts)
        s.recentEventTimes.append(ts)
        if s.recentEventTimes.count > 400 { s.recentEventTimes.removeFirst(s.recentEventTimes.count - 400) }
        if let m = o["model"] as? String, !m.isEmpty { s.model = m }
        if let w = o["workspace"] as? String { s.workspace = w }

        if event.hasPrefix("guardDeny") {
            s.guardBlocks += 1
        } else if event == "stop" {
            s.running = false
            s.lastStatus = o["status"] as? String
        } else {
            if !s.running {  // first event of a new agent run
                s.running = true
                s.runToolEvents = 0
                s.runCommands = [:]
                s.runFiles = [:]
            }
            switch event {
            case "afterShellExecution":
                s.runToolEvents += 1
                if let c = o["command"] as? String { s.runCommands[Signals.normalizeCommand(c), default: 0] += 1 }
            case "afterFileEdit":
                s.runToolEvents += 1
                if let f = o["file_path"] as? String { s.runFiles[f, default: 0] += 1 }
            case "afterMCPExecution":
                s.runToolEvents += 1
            default:
                break
            }
        }
        threads[id] = s
    }

    private func prune(now: Date) {
        threads = threads.filter { now.timeIntervalSince($0.value.lastEventAt) < 24 * 3600 }
    }
}

/// Used by `goldiectl hook`: turn a Cursor hook payload (stdin JSON) into one small log line and,
/// for the opt-in guard events, answer Cursor with allow/deny.
/// Only metadata is kept: no prompts, agent text, file contents or command output.
public enum HookRecorder {
    /// Returns what to print to Cursor on stdout.
    public static func handle(stdin: Data, eventArg: String?, file: URL = Paths.hookEventsFile,
                              configURL: URL = Paths.configFile, now: Date = Date()) -> String {
        let payload = J.obj(stdin) ?? [:]
        let event = (payload["hook_event_name"] as? String) ?? eventArg ?? "unknown"
        var output = "{}"
        if event == Guards.shellEvent || event == Guards.readEvent {
            // Fail open with "no opinion": a Goldie problem must never block (or auto-approve) anything.
            let guards = GoldieConfig.load(from: configURL).guards
            if let decision = Guards.decide(event: event, payload: payload, config: guards, recent: tail(file), now: now) {
                if let data = try? JSONSerialization.data(withJSONObject: decision.output),
                   let text = String(data: data, encoding: .utf8) { output = text }
                if let denied = decision.denied { append(denied, to: file) }
            }
        }
        record(payload: payload, event: event, to: file, now: now)
        return output
    }

    public static func record(stdin: Data, eventArg: String?, to file: URL = Paths.hookEventsFile) {
        let payload = J.obj(stdin) ?? [:]
        record(payload: payload, event: (payload["hook_event_name"] as? String) ?? eventArg ?? "unknown", to: file, now: Date())
    }

    static func record(payload: [String: Any], event: String, to file: URL, now: Date) {
        var rec: [String: Any] = ["ts": now.timeIntervalSince1970, "event": event]
        for key in ["conversation_id", "generation_id", "model", "status", "file_path", "cursor_version"] {
            if let v = payload[key] as? String { rec[key] = String(v.prefix(300)) }
        }
        if let c = payload["command"] as? String { rec["command"] = String(c.prefix(300)) }
        if let roots = payload["workspace_roots"] as? [String], let first = roots.first { rec["workspace"] = first }
        if let n = J.number(payload["loop_count"]) { rec["loop_count"] = n }
        rec["keys"] = payload.keys.sorted()  // helps us learn the payload schema per Cursor version
        append(rec, to: file)
    }

    static func append(_ rec: [String: Any], to file: URL) {
        guard JSONSerialization.isValidJSONObject(rec), var line = try? JSONSerialization.data(withJSONObject: rec) else { return }
        line.append(0x0A)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
        close(fd)
    }

    /// The last ~128 KB of the log, parsed (enough to see the current task).
    static func tail(_ file: URL, maxBytes: UInt64 = 128_000) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // partial first line
        return lines.compactMap { J.obj(String($0)) }
    }
}
