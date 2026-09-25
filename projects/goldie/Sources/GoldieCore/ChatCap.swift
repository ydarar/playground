import Foundation

/// A chat whose Cursor spend this month is at or over `chatCapUSD`.
public struct CapChat: Codable, Equatable, Identifiable {
    public var id: String
    /// Cursor's chat name ("" when unknown).
    public var title: String
    public var spentUSD: Double
    public var lastAt: Date
    /// Still in Goldie's active chat list.
    public var active: Bool

    public init(id: String, title: String, spentUSD: Double, lastAt: Date, active: Bool) {
        self.id = id
        self.title = title
        self.spentUSD = spentUSD
        self.lastAt = lastAt
        self.active = active
    }
}

/// Name and sub-task chats of any Cursor chat, including closed ones (from its composerData).
public struct ChatInfo: Equatable {
    public var title: String
    public var subagentIds: [String]

    public init(title: String, subagentIds: [String]) {
        self.title = title
        self.subagentIds = subagentIds
    }
}

/// Per-chat spending cap: every chat this month that has cost more than `chatCapUSD`, open or closed.
public enum ChatCap {
    /// Month-to-date $ and last charge per top-level chat. Only events Cursor tied to a chat
    /// (`conversationId`) count; sub-task chats roll up to their parent (`parents`: sub → parent).
    public static func totals(_ events: [UsageEvent], parents: [String: String]) -> [String: (usd: Double, lastAt: Date)] {
        var out: [String: (usd: Double, lastAt: Date)] = [:]
        for e in events {
            guard let conversation = e.conversationId, !conversation.isEmpty else { continue }
            let chat = parents[conversation] ?? conversation
            let prior = out[chat] ?? (usd: 0, lastAt: e.at)
            out[chat] = (usd: prior.usd + e.cents / 100, lastAt: max(prior.lastAt, e.at))
        }
        return out
    }

    /// Sub-task chat → parent, from chat info plus the live threads' own lists.
    public static func parents(info: [String: ChatInfo], threads: [ThreadSnapshot]) -> [String: String] {
        var out: [String: String] = [:]
        for (id, i) in info { for sub in i.subagentIds where sub != id { out[sub] = id } }
        for t in threads { for sub in t.subagentIds where sub != t.id { out[sub] = t.id } }
        return out
    }

    /// Chats at or over the cap, biggest first. Active chats use their live spend so the list and
    /// the chat rows always agree. `cap <= 0` turns the cap off.
    public static func overCap(events: [UsageEvent], cap: Double, info: [String: ChatInfo], threads: [ThreadSnapshot]) -> [CapChat] {
        guard cap > 0 else { return [] }
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CapChat] = []
        for (id, total) in totals(events, parents: parents(info: info, threads: threads)) {
            let live = byID[id]
            let usd = max(live?.spentUSD ?? 0, total.usd)
            guard usd >= cap else { continue }
            let title = live?.title ?? info[id]?.title ?? ""
            out.append(CapChat(id: id, title: title, spentUSD: usd, lastAt: total.lastAt, active: live != nil))
        }
        return out.sorted { $0.spentUSD != $1.spentUSD ? $0.spentUSD > $1.spentUSD : $0.id < $1.id }
    }

    /// For `goldiectl usage`: how chat costs are spread this month, to pick a sensible cap.
    /// Chat ids and titles are never printed.
    static func distribution(_ events: [UsageEvent], cap: Double) -> [String] {
        let chats = totals(events, parents: [:]).values.map(\.usd).sorted()
        guard !chats.isEmpty else { return ["", "# Per-chat spend: no events tied to a chat yet"] }
        func pct(_ p: Double) -> Double { chats[min(chats.count - 1, Int(Double(chats.count - 1) * p))] }
        func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
        let month = events.reduce(0) { $0 + $1.cents } / 100
        let over = chats.filter { cap > 0 && $0 >= cap }
        let overSum = over.reduce(0, +)
        return [
            "", "# Per-chat spend this month (sub-task chats counted separately here)",
            "  chats: \(chats.count) · median \(usd(pct(0.5))) · p90 \(usd(pct(0.9))) · max \(usd(chats.last ?? 0))",
            "  over the \(usd(cap)) chat cap: \(over.count) chats, \(usd(overSum))"
                + (month > 0 ? " (\(Int((overSum / month * 100).rounded()))% of the month)" : ""),
        ]
    }
}

extension ThreadSnapshot {
    /// This chat has cost at least the configured per-chat cap this month.
    public func isOverCap(_ config: GoldieConfig) -> Bool {
        config.chatCapUSD > 0 && (spentUSD ?? 0) >= config.chatCapUSD
    }
}
