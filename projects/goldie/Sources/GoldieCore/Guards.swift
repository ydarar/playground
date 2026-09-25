import Foundation

/// Opt-in prevention, answered from Cursor's before-* hooks. Both guards are narrow on purpose:
/// they only stop steps that are almost certainly wasted, and they explain themselves to the agent.
public enum Guards {
    public static let shellEvent = "beforeShellExecution"
    public static let readEvent = "beforeReadFile"
    public static let events = [shellEvent, readEvent]

    public struct Decision {
        /// JSON for Cursor, e.g. {"permission": "deny", "userMessage": …, "agentMessage": …}.
        public var output: [String: Any]
        /// Extra log line when something was blocked (so Goldie can show it and allow overrides).
        public var denied: [String: Any]?
    }

    /// "No opinion": an empty reply, so Cursor's own approval rules still apply.
    /// (Answering "allow" could auto-approve commands you'd normally confirm.)
    static let allow: [String: Any] = [:]

    public static func decide(event: String, payload: [String: Any], config: GuardConfig,
                              recent: [[String: Any]], now: Date) -> Decision? {
        let conversation = (payload["conversation_id"] as? String) ?? "unknown"
        switch event {
        case shellEvent:
            return shell(payload, conversation: conversation, config: config, recent: recent, now: now)
        case readEvent:
            return read(payload, conversation: conversation, config: config, recent: recent, now: now)
        default:
            return nil
        }
    }

    /// Loop guard: the same command already ran N times in this task with no file edited in between.
    /// Running it again can't produce a different result.
    static func shell(_ payload: [String: Any], conversation: String, config: GuardConfig,
                      recent: [[String: Any]], now: Date) -> Decision {
        guard config.loopGuard, let raw = payload["command"] as? String else { return Decision(output: allow) }
        let command = Signals.normalizeCommand(String(raw.prefix(300)))
        var count = 0
        for e in recent.reversed() where (e["conversation_id"] as? String) == conversation {
            let event = (e["event"] as? String) ?? ""
            if event == "stop" || event == "afterFileEdit" { break }  // new task, or code changed: not a loop
            if event == "afterShellExecution", let c = e["command"] as? String, Signals.normalizeCommand(c) == command {
                count += 1
            }
        }
        guard count >= config.loopRepeatLimit else { return Decision(output: allow) }
        let short = String(command.prefix(60))
        return Decision(
            output: [
                "permission": "deny",
                "userMessage": "🐠 Goldie blocked a repeat of `\(short)` (already ran \(count)× with no code changes).",
                "agentMessage": "Goldie loop guard: `\(short)` has already run \(count) times in this task with no file edits in between, so running it again will give the same result and just re-send the whole conversation. Stop repeating it. Re-read the last output, form a new hypothesis, change the code, or ask the user.",
            ],
            denied: ["ts": now.timeIntervalSince1970, "event": "guardDenyShell", "conversation_id": conversation, "command": short]
        )
    }

    /// Big-read guard: files over the limit are refused once. Asking again for the same file
    /// within 10 minutes is allowed (the agent really needs it).
    static func read(_ payload: [String: Any], conversation: String, config: GuardConfig,
                     recent: [[String: Any]], now: Date) -> Decision {
        guard config.readGuard, let path = payload["file_path"] as? String,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attrs[.size] as? NSNumber)?.intValue,
              bytes > config.readLimitKB * 1024 else { return Decision(output: allow) }
        let askedBefore = recent.contains { e in
            (e["event"] as? String) == "guardDenyRead"
                && (e["conversation_id"] as? String) == conversation
                && (e["file_path"] as? String) == path
                && now.timeIntervalSince1970 - (J.number(e["ts"]) ?? 0) < 600
        }
        if askedBefore { return Decision(output: allow) }
        let name = (path as NSString).lastPathComponent
        let kb = bytes / 1024
        return Decision(
            output: [
                "permission": "deny",
                "userMessage": "🐠 Goldie asked the agent to search \(name) (\(kb) KB) instead of reading all of it.",
                "agentMessage": "Goldie big-read guard: \(name) is \(kb) KB (~\(bytes / 4000)k tokens). Anything you read stays in the conversation and is re-sent on every later step. Search it (grep/rg) for what you need or read a specific line range. If you truly need the whole file, request it again and it will be allowed.",
            ],
            denied: ["ts": now.timeIntervalSince1970, "event": "guardDenyRead", "conversation_id": conversation, "file_path": path]
        )
    }
}

public extension Guards.Decision {
    init(output: [String: Any]) {
        self.init(output: output, denied: nil)
    }
}
