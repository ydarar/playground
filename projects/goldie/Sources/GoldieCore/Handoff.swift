import Foundation

/// The parts of a thread worth carrying into a fresh one.
public struct HandoffSource {
    public var title: String
    public var model: String?
    public var goal: String
    public var recentAsks: [String]
    public var lastReply: String
    public var files: [String]
    public var repeatedCommands: [(command: String, count: Int)]

    public init(thread: CursorThread) {
        let users = thread.bubbles.filter { $0.isUser && !$0.text.isEmpty }
        title = thread.title
        model = thread.model
        goal = users.first?.text ?? ""
        recentAsks = users.dropFirst().suffix(3).map(\.text)
        lastReply = thread.bubbles.last(where: { !$0.isUser && !$0.isTool && !$0.text.isEmpty })?.text ?? ""

        var seen = Set<String>()
        var files: [String] = []
        for b in thread.bubbles.reversed() {
            guard let f = b.filePath, !seen.contains(f) else { continue }
            seen.insert(f)
            files.append(f)
            if files.count == 15 { break }
        }
        self.files = files

        var counts: [String: Int] = [:]
        for b in thread.bubbles { if let c = b.command { counts[Signals.normalizeCommand(c), default: 0] += 1 } }
        repeatedCommands = counts.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.prefix(5).map { (command: $0.key, count: $0.value) }
    }
}

public enum Handoff {
    /// Template handoff. Free, instant, and the input to the optional LLM rewrite.
    public static func draft(_ s: HandoffSource) -> String {
        var out = "I'm continuing work from a previous agent thread"
        if !s.title.isEmpty { out += " (\"\(s.title.clipped(80))\")" }
        out += ". It got too long, so this is a fresh start. Keep context small and only read files you need.\n\n"

        out += "## Goal\n\(s.goal.isEmpty ? "<describe the goal>" : s.goal.clipped(700))\n\n"
        if !s.recentAsks.isEmpty {
            out += "## Latest asks\n" + s.recentAsks.map { "- \($0.clipped(300))" }.joined(separator: "\n") + "\n\n"
        }
        if !s.lastReply.isEmpty {
            out += "## Where things stand (last agent reply, trimmed)\n\(s.lastReply.clipped(900))\n\n"
        }
        if !s.files.isEmpty {
            out += "## Files that matter\n" + s.files.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.repeatedCommands.isEmpty {
            out += "## Don't repeat\n" + s.repeatedCommands.map { "- `\($0.command)` already ran \($0.count)× without converging" }
                .joined(separator: "\n") + "\n\n"
        }
        out += "## Next step\n<the next concrete step>\n"
        return out
    }
}

/// Saves handoff docs into the chat's repo (`.goldie/handoffs/`), kept out of git via `.git/info/exclude`
/// so your tracked `.gitignore` is never touched.
public enum HandoffWriter {
    public static func write(_ text: String, title: String, workspace: String?, now: Date) -> (url: URL, relativePath: String)? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let dir = root.appendingPathComponent(".goldie/handoffs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = slug(title) + "-" + stamp(now) + ".md"
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            excludeFromGit(root)
            return (url, ".goldie/handoffs/" + name)
        } catch {
            return nil
        }
    }

    /// The short opening message for the new chat.
    public static func prompt(relativePath: String) -> String {
        "Continue the work described in @\(relativePath). Read that file first, then open only the files you actually need. Keep this chat focused."
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        let trimmed = String(out.prefix(40))
        return trimmed.isEmpty ? "chat" : trimmed
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: date)
    }

    static func excludeFromGit(_ root: URL) {
        let gitDir = root.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let info = gitDir.appendingPathComponent("info", isDirectory: true)
        try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let exclude = info.appendingPathComponent("exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        let already = current.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == ".goldie/" }
        guard !already else { return }
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try? (current + separator + "# Goldie handoff docs\n.goldie/\n").write(to: exclude, atomically: true, encoding: .utf8)
    }
}
