import Foundation

/// What kind of work a task was. Model fit is judged per kind: the best model for a
/// hard debugging session isn't necessarily the best one for a mechanical rename.
public enum TaskKind: String, Codable, CaseIterable {
    case exploring, planning, debugging, refactor, feature

    public var label: String {
        switch self {
        case .exploring: return "Exploring code"
        case .planning: return "Planning / Q&A"
        case .debugging: return "Debugging"
        case .refactor: return "Refactors & mechanical edits"
        case .feature: return "Building features"
        }
    }

    /// Deterministic and local: your words plus what the agent actually did.
    public static func classify(text: String, edits: Int, commands: Int) -> TaskKind {
        let t = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["fix", "bug", "error", "failing", "fails", "broken", "crash", "debug", "exception",
                "stack trace", "doesn't work", "not working", "flaky"]) { return .debugging }
        if has(["refactor", "rename", "extract", "clean up", "cleanup", "reorganize", "migrate", "convert",
                "move "]) { return .refactor }
        if edits == 0 && commands == 0 {
            return has(["plan", "design", "approach", "should we", "how would", "explain", "why", "?"]) ? .planning : .exploring
        }
        return edits > 0 ? .feature : .exploring
    }
}

/// One task: a message you sent and everything the agent did until your next message.
public struct TaskSegment: Codable, Equatable {
    public var threadID: String
    public var model: String?
    public var kind: TaskKind
    public var start: Date
    public var end: Date
    public var steps: Int
    /// Most times one command was re-run or one file re-edited within the task.
    public var maxRepeat: Int
    /// A later message exists, or the agent has stopped.
    public var complete: Bool
    /// Your next message came quickly and reads like "still broken / try again".
    public var reasked: Bool
    /// Real $ from Cursor usage, filled in by CostModel.
    public var costUSD: Double?

    public var id: String { "\(threadID)@\(Int(start.timeIntervalSince1970))" }
    /// Looped or needed redoing.
    public var troubled: Bool { reasked || maxRepeat >= 3 }
}

enum TaskSegmenter {
    static let correctionPhrases = ["still", "doesn't work", "does not work", "not working", "didn't work", "wrong",
                                    "that's not", "try again", "same error", "broken", "revert", "undo", "no,", "nope"]

    static func looksLikeCorrection(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("no ") || correctionPhrases.contains { t.contains($0) }
    }

    static func segments(threadID: String, model: String?, bubbles: [CursorBubble], running: Bool, now: Date) -> [TaskSegment] {
        let userIndices = bubbles.indices.filter { bubbles[$0].isUser }
        var out: [TaskSegment] = []
        for (n, ui) in userIndices.enumerated() {
            let user = bubbles[ui]
            guard let start = user.createdAt else { continue }
            let nextUser = n + 1 < userIndices.count ? userIndices[n + 1] : bubbles.count
            let work = bubbles[(ui + 1)..<nextUser]

            var edits = 0
            var commands = 0
            var commandCounts: [String: Int] = [:]
            var fileCounts: [String: Int] = [:]
            for b in work where b.isTool {
                if b.isEdit { edits += 1 }
                if let c = b.command {
                    commands += 1
                    commandCounts[Signals.normalizeCommand(c), default: 0] += 1
                }
                if b.isEdit, let f = b.filePath { fileCounts[f, default: 0] += 1 }
            }
            let end = work.compactMap(\.createdAt).max() ?? start
            let isLast = nextUser == bubbles.count
            var reasked = false
            if !isLast, let next = bubbles[nextUser].createdAt, next.timeIntervalSince(end) < 300 {
                reasked = looksLikeCorrection(bubbles[nextUser].text)
            }
            out.append(TaskSegment(
                threadID: threadID,
                model: model,
                kind: TaskKind.classify(text: user.text, edits: edits, commands: commands),
                start: start,
                end: end,
                steps: work.count,
                maxRepeat: max(commandCounts.values.max() ?? 0, fileCounts.values.max() ?? 0),
                complete: !isLast || (!running && now.timeIntervalSince(end) > 120),
                reasked: reasked,
                costUSD: nil
            ))
        }
        return Array(out.suffix(30))
    }
}

/// Completed, priced tasks, kept on disk so model fit can learn over weeks.
public final class TaskStore {
    private let file: URL
    public private(set) var tasks: [String: TaskSegment] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast

    public init(file: URL = Paths.supportDir.appendingPathComponent("tasks.jsonl")) {
        self.file = file
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            if let t = try? decoder.decode(TaskSegment.self, from: Data(line.utf8)) { tasks[t.id] = t }
        }
    }

    public var all: [TaskSegment] { Array(tasks.values) }

    /// Keeps only finished tasks with a known cost.
    /// - A task is first recorded only if it ended recently: Goldie saw it happen, so the chat's
    ///   current model is the model it ran on (a later model switch can't relabel history).
    /// - Once stored, its model and kind never change; cost only grows (late charges), never shrinks
    ///   (older tasks can fall outside the time window used to match charges).
    public func record(_ segments: [TaskSegment], now: Date) {
        for s in segments where s.complete {
            guard let cost = s.costUSD else { continue }
            if var existing = tasks[s.id] {
                let merged = max(existing.costUSD ?? 0, cost)
                let steps = max(existing.steps, s.steps)
                let reasked = existing.reasked || s.reasked
                if merged != existing.costUSD || steps != existing.steps || reasked != existing.reasked {
                    existing.costUSD = merged
                    existing.steps = steps
                    existing.reasked = reasked
                    existing.maxRepeat = max(existing.maxRepeat, s.maxRepeat)
                    tasks[s.id] = existing
                    dirty = true
                }
            } else if now.timeIntervalSince(s.end) < 2 * 3600 {
                tasks[s.id] = s
                dirty = true
            }
        }
        if dirty && now.timeIntervalSince(lastSave) > 60 { save(now: now) }
    }

    public func save(now: Date) {
        let cutoff = now.addingTimeInterval(-90 * 24 * 3600)
        tasks = tasks.filter { $0.value.start >= cutoff }
        let encoder = JSONEncoder()
        let lines = tasks.values.sorted { $0.start < $1.start }.compactMap { t -> String? in
            guard let data = try? encoder.encode(t) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        dirty = false
        lastSave = now
    }
}

/// How a model has actually performed for you on one kind of work.
public struct ModelStats: Equatable {
    public var kind: TaskKind
    public var model: String
    public var count: Int
    public var medianCostUSD: Double
    public var medianSteps: Int
    /// Share of tasks that looped or needed redoing.
    public var troubleRate: Double
    /// What a task that actually worked costs, counting the ones you had to redo.
    public var costPerGoodTaskUSD: Double
}

public enum ModelFit {
    /// Don't advise on thin evidence.
    public static let minTasks = 5

    public static func stats(_ tasks: [TaskSegment], since: Date) -> [ModelStats] {
        var groups: [String: [TaskSegment]] = [:]
        for t in tasks where t.start >= since {
            guard let cost = t.costUSD, cost > 0, let model = t.model?.lowercased(), !model.isEmpty else { continue }
            groups["\(t.kind.rawValue)|\(model)", default: []].append(t)
        }
        return groups.compactMap { key, list -> ModelStats? in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = TaskKind(rawValue: parts[0]) else { return nil }
            let costs = list.compactMap(\.costUSD).sorted()
            let steps = list.map(\.steps).sorted()
            let trouble = Double(list.filter(\.troubled).count) / Double(list.count)
            let median = costs[costs.count / 2]
            return ModelStats(kind: kind, model: parts[1], count: list.count, medianCostUSD: median,
                              medianSteps: steps[steps.count / 2], troubleRate: trouble,
                              costPerGoodTaskUSD: median / max(0.2, 1 - trouble))
        }
        .sorted { ($0.kind.rawValue, $0.costPerGoodTaskUSD) < ($1.kind.rawValue, $1.costPerGoodTaskUSD) }
    }

    /// A suggestion only when both sides have enough tasks and the gap is big (≥25%).
    /// It can point to a *pricier* model when that one needs less redoing.
    public static func advice(kind: TaskKind, model: String?, stats: [ModelStats]) -> String? {
        guard let model = model?.lowercased(),
              let current = stats.first(where: { $0.kind == kind && $0.model == model && $0.count >= minTasks }) else { return nil }
        let better = stats
            .filter { $0.kind == kind && $0.model != model && $0.count >= minTasks }
            .min { $0.costPerGoodTaskUSD < $1.costPerGoodTaskUSD }
        guard let better, better.costPerGoodTaskUSD <= current.costPerGoodTaskUSD * 0.75 else { return nil }
        return String(format: "For %@, %@ has cost you ~$%.2f per task that worked (%ld tasks, %.0f%% redone) vs ~$%.2f on %@ (%ld tasks, %.0f%% redone).",
                      kind.label.lowercased(), better.model, better.costPerGoodTaskUSD, better.count, better.troubleRate * 100,
                      current.costPerGoodTaskUSD, current.model, current.count, current.troubleRate * 100)
    }
}
