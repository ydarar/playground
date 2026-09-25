import Foundation

/// Everything Goldie knows about one live thread. Deterministic, cheap, and what the brain sees.
public struct ThreadSnapshot: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var model: String?
    public var maxMode: Bool
    public var userTurns: Int
    public var messages: Int
    /// Tokens re-sent on every turn (reported, from the last request, or estimated from text).
    public var contextTokens: Int
    /// "reported" | "lastRequest" | "estimated" | "unknown"
    public var contextSource: String
    /// contextTokens / freshBaselineTokens: how many fresh starts one more turn costs.
    public var contextRatio: Double
    /// Cost of one agent step (one model call). Every step re-sends the whole context.
    /// From Cursor's usage data when available, else from a configured price.
    public var nextTurnCostUSD: Double?
    public var toolCallsSinceUser: Int
    public var maxRepeatCommand: Int
    public var maxRepeatFileEdit: Int
    /// 0...1, how much the current run looks like a non-converging loop.
    public var loopScore: Double
    public var running: Bool
    public var lastActivity: Date

    // Filled in by CostModel from Cursor usage events (nil when unavailable).
    public var spentUSD: Double? = nil
    /// Everything your latest message triggered (all its steps).
    public var lastMessageUSD: Double? = nil
    /// "cursor" (matched usage events) | "cursor-rate" (tokens × your observed rate) | "config" | "none"
    public var costSource: String = "none"

    public var lastUserAt: Date? = nil
    public var topRepeatedCommand: String? = nil
    public var topRepeatedFile: String? = nil
    /// Recent agent activity timestamps, used to match usage events to this thread. Not sent to the brain.
    public var activityTimes: [Date] = []

    /// Recent tasks (your message → agent done), newest last; CostModel fills in their $.
    public var tasks: [TaskSegment] = []
    /// Largest single tool result (a file read, a log, command output) that every later step re-sends.
    public var bloatLabel: String? = nil
    public var bloatTokens: Int = 0
    /// Context size of the very first request: what a chat costs before you've typed anything.
    public var startTokens: Int? = nil

    /// The exact model Cursor billed for the latest request (e.g. "grok-4.7-high-fast").
    public var billedModel: String? = nil
    /// Model as billed if known, else the chat's setting.
    public var effectiveModel: String? { billedModel ?? model }

    /// Folder the chat works in (from Cursor hooks); handoff docs are written there.
    public var workspace: String? = nil
    /// Times Goldie's guards stopped a wasteful step in this chat.
    public var guardBlocks: Int = 0

    /// Cursor sub-task chats spawned by this chat; their costs roll up here.
    public var subagentIds: [String] = []

    public var currentKind: TaskKind? { tasks.last?.kind }

    public func advice(config: GoldieConfig, now: Date) -> ChatAdvice {
        ChatAdvice.decide(self, config: config, now: now)
    }

    /// What this chat is mostly doing: recent tasks weighted by steps (one question doesn't relabel it).
    public var dominantKind: TaskKind? {
        let recent = tasks.suffix(5)
        guard !recent.isEmpty else { return nil }
        var weight: [TaskKind: Int] = [:]
        for t in recent { weight[t.kind, default: 0] += max(1, t.steps) }
        return weight.max { $0.value < $1.value }?.key
    }
}

public struct Snapshot: Codable, Equatable {
    /// Active threads, most recent first.
    public var threads: [ThreadSnapshot]
    public var parallelCount: Int
    public var takenAt: Date
    public var cursorDBFound: Bool
    public var hookEventsSeen: Bool
    /// What a fresh chat costs to start, learned from your chats (the "N× cheaper" yardstick).
    public var freshBaselineTokens: Int = 0
    public var todayUSD: Double? = nil
    public var monthUSD: Double? = nil
    /// Month-to-date spend from other tools (Claude, Codex, OpenCode) that counts toward the budget.
    public var otherSourcesMonthUSD: Double = 0
    /// True when at least one non-Cursor tool is connected (so a $0 total still shows as $0).
    public var otherSourcesConnected: Bool = false
    /// All tools' month-to-date spend extrapolated to the end of the month.
    public var projectedMonthUSD: Double? = nil

    /// Everything that counts toward the AI token budget (Cursor + other tools).
    public var totalMonthUSD: Double? {
        if monthUSD == nil && !otherSourcesConnected { return nil }
        return (monthUSD ?? 0) + otherSourcesMonthUSD
    }

    /// Recomputes the projection from all tools' spend (call after setting `otherSourcesMonthUSD`).
    public mutating func projectTotal(now: Date) {
        guard let total = totalMonthUSD, let interval = Calendar.current.dateInterval(of: .month, for: now) else { return }
        let elapsed = max(now.timeIntervalSince(interval.start), 24 * 3600)
        projectedMonthUSD = total * interval.duration / elapsed
    }

    public static let empty = Snapshot(threads: [], parallelCount: 0, takenAt: .distantPast, cursorDBFound: false, hookEventsSeen: false)

    public func thread(_ id: String?) -> ThreadSnapshot? {
        guard let id else { return nil }
        return threads.first { $0.id == id }
    }
}

public enum Signals {
    public static func build(id: String, thread: CursorThread?, hook: HookThreadState?, config: GoldieConfig, now: Date) -> ThreadSnapshot {
        let bubbles = thread?.bubbles ?? []

        // Loop signals: tool activity since the user last spoke.
        let tail: ArraySlice<CursorBubble>
        if let lastUser = bubbles.lastIndex(where: { $0.isUser }) {
            tail = bubbles[(lastUser + 1)...]
        } else {
            tail = bubbles[...]
        }
        var toolCalls = 0
        var commands: [String: Int] = [:]
        var files: [String: Int] = [:]
        for b in tail where b.isTool {
            toolCalls += 1
            if let c = b.command { commands[normalizeCommand(c), default: 0] += 1 }
            if b.isEdit, let f = b.filePath { files[f, default: 0] += 1 }
        }
        if let h = hook {  // hooks are real-time; the DB can lag, so take the max of both views
            toolCalls = max(toolCalls, h.runToolEvents)
            for (k, v) in h.runCommands { commands[k] = max(commands[k] ?? 0, v) }
            for (k, v) in h.runFiles { files[k] = max(files[k] ?? 0, v) }
        }
        let topCommand = commands.max { $0.value < $1.value }
        let topFile = files.max { $0.value < $1.value }
        let maxCommand = topCommand?.value ?? 0
        let maxFile = topFile?.value ?? 0

        let (context, source) = contextEstimate(thread, config: config)
        let ratio = context > 0 ? Double(context) / Double(max(config.freshBaselineTokens, 1)) : 0
        let model = thread?.model ?? hook?.model
        let running = (hook?.running ?? false) && now.timeIntervalSince(hook?.lastEventAt ?? .distantPast) < 180
        let lastActivity = [thread?.lastUpdatedAt, bubbles.last?.createdAt, hook?.lastEventAt]
            .compactMap { $0 }.max() ?? .distantPast

        let title = thread?.title.isEmpty == false ? thread!.title : "Cursor thread \(id.prefix(6))"
        let bubbleTimes = bubbles.filter { !$0.isUser }.compactMap(\.createdAt)
        let activity = Array((bubbleTimes + (hook?.recentEventTimes ?? [])).sorted().suffix(400))
        var snap = ThreadSnapshot(
            id: id,
            title: title,
            model: model,
            maxMode: thread?.maxMode ?? false,
            userTurns: bubbles.filter(\.isUser).count,
            messages: bubbles.count,
            contextTokens: context,
            contextSource: source,
            contextRatio: ratio,
            nextTurnCostUSD: nextTurnCost(tokens: context, model: model, config: config),
            toolCallsSinceUser: toolCalls,
            maxRepeatCommand: maxCommand,
            maxRepeatFileEdit: maxFile,
            loopScore: loopScore(toolCalls: toolCalls, maxRepeatCommand: maxCommand, maxRepeatFileEdit: maxFile),
            running: running,
            lastActivity: lastActivity
        )
        snap.lastUserAt = bubbles.last(where: { $0.isUser })?.createdAt
        snap.topRepeatedCommand = maxCommand >= 2 ? topCommand?.key : nil
        snap.topRepeatedFile = maxFile >= 2 ? topFile?.key : nil
        snap.activityTimes = activity
        snap.tasks = TaskSegmenter.segments(threadID: id, model: model, bubbles: bubbles, running: running, now: now)
        // Measure the tool *result* only (not args, attachments or internal copies of the message).
        if let biggest = bubbles.filter({ $0.isTool && !$0.resultIsImage }).max(by: { $0.resultLength < $1.resultLength }),
           biggest.resultLength >= 40_000 {
            snap.bloatTokens = biggest.resultLength / 4
            snap.bloatLabel = biggest.filePath.map { ($0 as NSString).lastPathComponent }
                ?? biggest.command.map { cmd in
                    let firstLine = cmd.split(separator: "\n").first.map(String.init) ?? cmd
                    return "output of `" + String(firstLine.prefix(40)) + "`"
                }
                ?? biggest.toolName
                ?? "a tool result"
        }
        snap.workspace = hook?.workspace
        snap.subagentIds = thread?.subagentIds ?? []
        snap.guardBlocks = hook?.guardBlocks ?? 0
        snap.startTokens = bubbles.first(where: { !$0.isUser && ($0.inputTokens ?? 0) > 0 })?.inputTokens
        if snap.nextTurnCostUSD != nil { snap.costSource = "config" }
        return snap
    }

    static func contextEstimate(_ thread: CursorThread?, config: GoldieConfig) -> (Int, String) {
        guard let thread else { return (0, "unknown") }
        if let reported = thread.reportedContextTokens, reported > 0 { return (reported, "reported") }
        if let last = thread.bubbles.last(where: { !$0.isUser && ($0.inputTokens ?? 0) > 0 })?.inputTokens {
            return (last, "lastRequest")
        }
        let bytes = thread.bubbles.reduce(0) { $0 + $1.textLength }
        guard bytes > 0 else { return (0, "unknown") }
        return (bytes / 4 + config.systemOverheadTokens, "estimated")  // ~4 bytes per token
    }

    public static func loopScore(toolCalls: Int, maxRepeatCommand: Int, maxRepeatFileEdit: Int) -> Double {
        let volume = Double(toolCalls) / 40                          // 40 tool calls without you → 1.0
        let commandRepeat = Double(max(0, maxRepeatCommand - 1)) / 4  // same command 5× → 1.0
        let fileRepeat = Double(max(0, maxRepeatFileEdit - 1)) / 6    // same file edited 7× → 1.0
        return min(1, max(volume, commandRepeat, fileRepeat))
    }

    public static func nextTurnCost(tokens: Int, model: String?, config: GoldieConfig) -> Double? {
        guard tokens > 0 else { return nil }
        let name = (model ?? "").lowercased()
        let match = config.inputPricePerMTok
            .filter { $0.key != "default" && !$0.key.isEmpty && name.contains($0.key.lowercased()) }
            .max { $0.key.count < $1.key.count }?.value
        guard let price = match ?? config.inputPricePerMTok["default"] else { return nil }
        let blended = config.cachedInputShare * config.cachedInputDiscount + (1 - config.cachedInputShare)
        return Double(tokens) / 1_000_000 * price * blended
    }

    public static func normalizeCommand(_ command: String) -> String {
        let collapsed = command.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(120))
    }
}

/// What to actually do about a chat. "Start fresh" is only right at a task boundary:
/// mid-task a new chat re-pays to rediscover everything, and an idle chat costs nothing.
public enum ChatAdvice: String, Codable {
    /// Light, or nothing to do.
    case fine
    /// Repeating itself: redirect it (another lap won't help).
    case redirect
    /// Heavy and waiting for you: the right moment to start the next task fresh.
    case freshNow
    /// Heavy but mid-task: let it finish here; start the *next* task fresh.
    case finishThenFresh
    /// Heavy but idle: costs nothing until you send another message.
    case idleHeavy

    public static func decide(_ t: ThreadSnapshot, config: GoldieConfig, now: Date) -> ChatAdvice {
        let idleMinutes = now.timeIntervalSince(t.lastActivity) / 60
        let stuck = t.loopScore >= 0.75 || t.maxRepeatCommand >= 3 || t.maxRepeatFileEdit >= 4
        if stuck && (t.running || idleMinutes < 15) { return .redirect }
        guard t.contextRatio >= config.heavyRatio else { return .fine }
        if idleMinutes > 30 { return .idleHeavy }
        return t.running ? .finishThenFresh : .freshNow
    }
}

/// Learns what a fresh chat really costs to start (system prompt, rules, tools and the first
/// message) from the smallest context each new chat was seen with. Persisted between launches.
public final class BaselineLearner {
    private let file: URL
    private var firstTurn: [String: Int] = [:]
    private var dirty = false

    public init(file: URL = Paths.supportDir.appendingPathComponent("baseline.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            firstTurn = saved
        }
    }

    /// Only chats still on their first message, with Cursor-reported context.
    public func observe(_ t: ThreadSnapshot) {
        guard t.userTurns == 1, t.contextSource == "reported", t.contextTokens > 0 else { return }
        let smallest = min(firstTurn[t.id] ?? Int.max, t.contextTokens)
        if firstTurn[t.id] != smallest {
            firstTurn[t.id] = smallest
            dirty = true
        }
    }

    /// Median of recent chats, clamped to a sane range; the configured value until 3 chats are seen.
    public func baseline(fallback: Int) -> Int {
        let values = firstTurn.values.sorted()
        guard values.count >= 3 else { return fallback }
        return min(max(values[values.count / 2], fallback), fallback * 4)
    }

    public func saveIfNeeded() {
        guard dirty else { return }
        if firstTurn.count > 60 {  // keep the most recent-ish 60 (dictionary order is arbitrary; fine for a median)
            firstTurn = Dictionary(uniqueKeysWithValues: firstTurn.map { ($0.key, $0.value) }.suffix(60))
        }
        if let data = try? JSONEncoder().encode(firstTurn) { try? data.write(to: file, options: .atomic) }
        dirty = false
    }
}
