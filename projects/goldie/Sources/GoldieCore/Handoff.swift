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
