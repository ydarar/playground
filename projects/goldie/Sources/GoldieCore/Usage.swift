import Foundation

/// One billed model call, as reported by Cursor's usage dashboard.
public struct UsageEvent: Codable, Hashable {
    public var at: Date
    public var model: String
    public var cents: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// The Cursor chat this request belonged to (exact per-chat attribution).
    public var conversationId: String? = nil
    // Kept for reconciling with the cursor.com dashboard (`goldiectl usage` prints the candidates).
    public var chargeable: Bool = true
    public var chargedCents: Double? = nil
    public var discountPercent: Double? = nil
    /// Price before discounts (`tokenUsage.totalCents`).
    public var listCents: Double? = nil

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// This month's usage events, merged incrementally.
public struct UsageLedger {
    public private(set) var events: [UsageEvent] = []
    public private(set) var lastMergeAt: Date?
    /// Set when a fetch hit the page cap: charges from the month start up to this date are still
    /// missing, so the next fetch goes back for them before totals are trusted.
    public private(set) var backfillUntil: Date?

    public init() {}

    /// Records how a fetch went. `since` is where it started; an incomplete fetch holds only its
    /// newest events, so everything older than its oldest event still needs fetching.
    public mutating func noteFetch(since: Date, events: [UsageEvent], complete: Bool, now: Date) {
        if complete {
            if since <= Self.monthStart(now) { backfillUntil = nil }
        } else if let oldest = events.map(\.at).min() {
            backfillUntil = min(backfillUntil ?? oldest, oldest)
        }
    }

    public var isEmpty: Bool { lastMergeAt == nil }

    /// Fetches overlap, so the same request can arrive twice, possibly with updated fields
    /// (e.g. charged amount). Identity is when/what/which chat; the newest copy wins.
    public mutating func merge(_ new: [UsageEvent], now: Date) {
        let monthStart = Self.monthStart(now)
        var byKey: [String: UsageEvent] = [:]
        for e in events + new { byKey[Self.identity(e)] = e }
        events = byKey.values.filter { $0.at >= monthStart }.sorted { $0.at < $1.at }
        lastMergeAt = now
    }

    static func identity(_ e: UsageEvent) -> String {
        "\(e.at.timeIntervalSince1970)|\(e.model)|\(e.conversationId ?? "-")|\(e.inputTokens)|\(e.outputTokens)|\(e.cacheReadTokens)"
    }

    /// Re-fetch a little overlap so late-arriving events aren't missed; duplicates merge away.
    public func fetchStart(now: Date) -> Date {
        let monthStart = Self.monthStart(now)
        guard lastMergeAt != nil, backfillUntil == nil, let last = events.last else { return monthStart }
        return max(monthStart, last.at.addingTimeInterval(-15 * 60))
    }

    public func totalUSD(since: Date) -> Double {
        events.reduce(0) { $1.at >= since ? $0 + $1.cents : $0 } / 100
    }

    /// Observed cents per token (all token kinds, so prompt caching is already priced in),
    /// per model over the last 7 days, plus "*" across all models.
    public func centsPerToken(now: Date) -> [String: Double] {
        let since = now.addingTimeInterval(-7 * 24 * 3600)
        var cents: [String: Double] = [:]
        var tokens: [String: Double] = [:]
        for e in events where e.at >= since && e.totalTokens > 0 && e.cents > 0 {
            for key in [e.model.lowercased(), "*"] {
                cents[key, default: 0] += e.cents
                tokens[key, default: 0] += Double(e.totalTokens)
            }
        }
        var out: [String: Double] = [:]
        for (k, c) in cents { if let t = tokens[k], t > 0 { out[k] = c / t } }
        return out
    }

    public static func monthStart(_ now: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: now)?.start ?? Calendar.current.startOfDay(for: now)
    }
}

/// Reads Cursor usage with the Cursor app's own login (from its local state DB).
public final class CursorUsageClient {
    let dbPath: String
    static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!

    public init(dbPath: String = Paths.cursorStateDB.path) {
        self.dbPath = dbPath
    }

    /// Same cookie cursor.com uses in the browser: `<userId>::<accessToken>` (URL-encoded).
    func sessionCookie() -> String? {
        guard let db = SQLiteReader(path: dbPath),
              let raw = J.string(db.firstValue("SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'")) else { return nil }
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !token.isEmpty, let user = Self.userID(fromJWT: token) else { return nil }
        return "WorkosCursorSessionToken=\(user)%3A%3A\(token)"
    }

    static func userID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let payload = J.obj(data), let sub = payload["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    public func fetchPage(since: Date, until: Date, page: Int, pageSize: Int) async throws -> (status: Int, body: [String: Any]?) {
        guard let cookie = sessionCookie() else { throw GoldieError("no Cursor login found (open Cursor and sign in)") }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let body: [String: Any] = [
            "startDate": String(Int64(since.timeIntervalSince1970 * 1000)),
            "endDate": String(Int64(until.timeIntervalSince1970 * 1000)),
            "page": page,
            "pageSize": pageSize,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, J.obj(data))
    }

    /// `complete` is false if we hit the page cap before running out of events (totals would be low).
    public func fetchAll(since: Date, until: Date, maxPages: Int = 150) async throws -> (events: [UsageEvent], complete: Bool) {
        var all: [UsageEvent] = []
        let pageSize = 100
        for page in 1...maxPages {
            let (status, body) = try await fetchPage(since: since, until: until, page: page, pageSize: pageSize)
            guard status == 200, let body else { throw GoldieError("Cursor usage API returned HTTP \(status)") }
            all += Self.parseEvents(body)
            // Stop on the raw page size: one unparseable event mustn't end paging early.
            let raw = ((body["usageEventsDisplay"] as? [Any]) ?? (body["usageEvents"] as? [Any]))?.count ?? 0
            if raw < pageSize { return (all, true) }
        }
        return (all, false)
    }

    static func parseEvents(_ body: [String: Any]) -> [UsageEvent] {
        let list = (body["usageEventsDisplay"] as? [[String: Any]]) ?? (body["usageEvents"] as? [[String: Any]]) ?? []
        return list.compactMap { e -> UsageEvent? in
            guard let at = J.date(e["timestamp"]) else { return nil }
            let usage = e["tokenUsage"] as? [String: Any] ?? [:]
            // What you're actually charged: `chargedCents` (after the enterprise discount). It matched the
            // cursor.com Usage total within 0.2% in testing; the list price `totalCents` was ~7% high.
            let listCents = J.number(usage["totalCents"]) ?? J.number(e["totalCents"]) ?? dollars(e["usageBasedCosts"]).map { $0 * 100 } ?? 0
            let discount = J.number(usage["enterpriseUsageDiscountPercent"]) ?? 0
            let chargeable = (e["isChargeable"] as? Bool) ?? true
            let cents = J.number(e["chargedCents"]) ?? (chargeable ? listCents * (1 - discount / 100) : 0)
            var event = UsageEvent(
                at: at,
                model: (e["model"] as? String) ?? "unknown",
                cents: cents,
                inputTokens: J.int(usage["inputTokens"]) ?? 0,
                outputTokens: J.int(usage["outputTokens"]) ?? 0,
                cacheReadTokens: J.int(usage["cacheReadTokens"]) ?? 0,
                cacheWriteTokens: J.int(usage["cacheWriteTokens"]) ?? 0
            )
            event.conversationId = e["conversationId"] as? String
            event.chargeable = chargeable
            event.chargedCents = J.number(e["chargedCents"])
            event.discountPercent = J.number(usage["enterpriseUsageDiscountPercent"])
            event.listCents = listCents
            return event
        }
    }

    /// "$0.12" → 0.12; "Included", "-" → nil.
    static func dollars(_ v: Any?) -> Double? {
        guard let s = v as? String else { return J.number(v) }
        return Double(s.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces))
    }
}

/// Puts real money on each thread by matching usage events to thread activity in time.
public enum CostModel {
    /// `parents` (sub-task chat → parent) adds roll-ups the live threads' own lists don't know, e.g. nested sub-tasks.
    public static func enrich(_ snap: Snapshot, ledger: UsageLedger, config: GoldieConfig, now: Date,
                              parents: [String: String] = [:]) -> Snapshot {
        var out = snap
        guard !ledger.isEmpty else { return out }
        out.todayUSD = ledger.totalUSD(since: Calendar.current.startOfDay(for: now))
        let month = ledger.totalUSD(since: UsageLedger.monthStart(now))
        out.monthUSD = month
        if let interval = Calendar.current.dateInterval(of: .month, for: now) {
            let elapsed = max(now.timeIntervalSince(interval.start), 24 * 3600)  // avoid wild day-1 projections
            out.projectedMonthUSD = month * interval.duration / elapsed
        }

        // Events Cursor tied to a chat always count, however old, so `spentUSD` is the chat's whole
        // month. Untied events are matched by time, so only those near recent activity are candidates.
        let earliest = snap.threads.compactMap { $0.activityTimes.first }.min() ?? now
        let monthStart = UsageLedger.monthStart(now)
        let candidates = ledger.events.filter {
            $0.at >= monthStart
                && (!($0.conversationId ?? "").isEmpty || $0.at >= earliest.addingTimeInterval(-config.attributionToleranceSeconds))
        }
        let assigned = attribute(candidates, to: snap.threads, tolerance: config.attributionToleranceSeconds, parents: parents)
        let rates = ledger.centsPerToken(now: now)

        for i in out.threads.indices {
            var t = out.threads[i]
            let events = assigned[t.id] ?? []
            if !events.isEmpty {
                t.spentUSD = events.reduce(0) { $0 + $1.cents } / 100
                if let lastUser = t.lastUserAt {
                    t.lastMessageUSD = events.filter { $0.at >= lastUser }.reduce(0) { $0 + $1.cents } / 100
                }
                // Price each task: the charges between its start and the next task's start.
                // The chat's own calls (not its sub-tasks') say what one step costs and which model it runs.
                let own = events.filter { $0.conversationId == t.id }
                let ownOrAll = own.isEmpty ? events : own
                for j in t.tasks.indices {
                    // Same 5 s slack on both edges, so a charge just before the next message is priced once.
                    let start = t.tasks[j].start.addingTimeInterval(-5)
                    let end = j + 1 < t.tasks.count ? t.tasks[j + 1].start.addingTimeInterval(-5) : Date.distantFuture
                    let inTask = events.filter { $0.at >= start && $0.at < end }
                    if !inTask.isEmpty {
                        t.tasks[j].costUSD = inTask.reduce(0) { $0 + $1.cents } / 100
                        t.tasks[j].steps = max(t.tasks[j].steps, inTask.count)
                        // The billed model is more precise than the chat's setting (e.g. reasoning effort).
                        let ownInTask = inTask.filter { $0.conversationId == t.id }
                        if let billed = dominantModel(ownInTask.isEmpty ? inTask : ownInTask) { t.tasks[j].model = billed }
                    }
                }
                if let lastTask = t.tasks.last?.costUSD { t.lastMessageUSD = lastTask }
                t.billedModel = ownOrAll.last?.model
                let recent = ownOrAll.suffix(3)
                t.nextTurnCostUSD = recent.reduce(0) { $0 + $1.cents } / Double(recent.count) / 100
                t.costSource = "cursor"
            } else if t.contextTokens > 0, let rate = rate(for: t.model, in: rates) {
                t.nextTurnCostUSD = Double(t.contextTokens) * rate / 100
                t.costSource = "cursor-rate"
            }
            out.threads[i] = t
        }
        return out
    }

    /// Exact when Cursor says which chat a request belonged to (`conversationId`); otherwise the
    /// thread with the nearest activity timestamp (within tolerance).
    static func attribute(_ events: [UsageEvent], to threads: [ThreadSnapshot], tolerance: Double,
                          parents: [String: String] = [:]) -> [String: [UsageEvent]] {
        var out: [String: [UsageEvent]] = [:]
        // A chat owns its own requests and those of the sub-task chats it spawned. Chats first, then
        // sub-tasks, so a sub-task that also shows up as a chat can't take its parent's place.
        var owner: [String: String] = [:]
        for t in threads { owner[t.id] = t.id }
        for t in threads { for sub in t.subagentIds where sub != t.id { owner[sub] = t.id } }
        // When Cursor tags chat requests with their chat, an untagged charge isn't a chat request
        // (inline edits, commit messages…): don't pin it on whichever chat was busy at the time.
        let tagged = events.filter { !($0.conversationId ?? "").isEmpty }.count
        let matchByTime = tagged * 2 < events.count
        for e in events {
            if let conversation = e.conversationId, !conversation.isEmpty {
                if let chat = ChatCap.root(of: conversation, parents: parents, stopAt: owner) { out[chat, default: []].append(e) }
                continue  // belongs to a chat Goldie isn't watching: never guess by time
            }
            guard matchByTime else { continue }
            var best: (id: String, distance: Double)?
            for t in threads {
                guard let d = nearestDistance(e.at, in: t.activityTimes), d <= tolerance else { continue }
                if best == nil || d < best!.distance { best = (id: t.id, distance: d) }
            }
            if let best { out[best.id, default: []].append(e) }
        }
        return out
    }

    static func dominantModel(_ events: [UsageEvent]) -> String? {
        var counts: [String: Int] = [:]
        for e in events where e.model != "unknown" { counts[e.model, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Distance in seconds to the closest time in a sorted array (binary search).
    static func nearestDistance(_ date: Date, in sorted: [Date]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0
        var hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < date { lo = mid + 1 } else { hi = mid }
        }
        var best = abs(sorted[lo].timeIntervalSince(date))
        if lo > 0 { best = min(best, abs(sorted[lo - 1].timeIntervalSince(date))) }
        return best
    }

    static func rate(for model: String?, in rates: [String: Double]) -> Double? {
        let name = (model ?? "").lowercased()
        if !name.isEmpty {
            if let exact = rates[name] { return exact }
            // Closest name wins (longest key, then alphabetical), never dictionary order.
            let fuzzy = rates.filter { $0.key != "*" && ($0.key.contains(name) || name.contains($0.key)) }
                .min { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key }
            if let fuzzy { return fuzzy.value }
        }
        return rates["*"]
    }
}

/// `goldiectl usage`: check the Cursor usage connection. Prints shapes and totals, never the token.
public enum UsageDiagnostics {
    /// Candidate month totals, to compare with cursor.com → Usage (refresh it first, month-to-date).
    static func reconciliation(_ events: [UsageEvent], now: Date) -> [String] {
        func usd(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }
        let shown = events.reduce(0) { $0 + $1.cents }
        let raw = events.reduce(0) { $0 + ($1.listCents ?? $1.cents) }
        let discounted = events.reduce(0) { $0 + ($1.listCents ?? $1.cents) * (1 - ($1.discountPercent ?? 0) / 100) }
        let chargeableOnly = events.filter(\.chargeable).reduce(0) { $0 + ($1.listCents ?? $1.cents) }
        let charged = events.compactMap(\.chargedCents)
        let discounts = Set(events.compactMap(\.discountPercent).map { String(format: "%.2f%%", $0) }).sorted()
        let utcStart: Date = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
            return cal.dateInterval(of: .month, for: now)?.start ?? now
        }()
        let fromUTC = events.filter { $0.at >= utcStart }.reduce(0) { $0 + $1.cents }
        var lines = ["", "# Month total candidates (which one matches cursor.com → Usage, refreshed just now?)"]
        lines.append("  Goldie shows (chargedCents, else discounted list price): \(usd(shown))")
        lines.append("  A raw totalCents (list price):              \(usd(raw))")
        lines.append("  B after enterpriseUsageDiscountPercent:     \(usd(discounted))   discount values seen: \(discounts.isEmpty ? "none" : discounts.joined(separator: ", "))")
        lines.append("  C chargeable events only:                   \(usd(chargeableOnly))   (\(events.filter { !$0.chargeable }.count) not chargeable)")
        lines.append("  D sum of chargedCents:                      \(charged.isEmpty ? "n/a" : usd(charged.reduce(0, +)))   (\(charged.count) events have it)")
        lines.append("  (checked at \(ISO8601DateFormatter().string(from: now)); month starts local \(ISO8601DateFormatter().string(from: UsageLedger.monthStart(now))), UTC month so far: \(usd(fromUTC)))")
        return lines
    }

    public static func report(dbPath: String = Paths.cursorStateDB.path) async -> String {
        var out = ["== Goldie usage check (no secrets printed) =="]
        let client = CursorUsageClient(dbPath: dbPath)
        guard client.sessionCookie() != nil else {
            out.append("!! No Cursor login token found in Cursor's state DB (key cursorAuth/accessToken).")
            return out.joined(separator: "\n")
        }
        out.append("Cursor login token: found")
        let now = Date()
        do {
            let (status, body) = try await client.fetchPage(since: UsageLedger.monthStart(now), until: now, page: 1, pageSize: 100)
            out.append("HTTP status: \(status)")
            guard let body else {
                out.append("!! Response wasn't JSON.")
                return out.joined(separator: "\n")
            }
            out.append("response keys: \(body.keys.sorted().joined(separator: ", "))")
            if let total = body["totalUsageEventsCount"] { out.append("totalUsageEventsCount: \(total)") }
            let list = (body["usageEventsDisplay"] as? [[String: Any]]) ?? (body["usageEvents"] as? [[String: Any]]) ?? []
            if let first = list.first {
                out.append("event keys: \(first.keys.sorted().joined(separator: ", "))")
                if let tu = first["tokenUsage"] as? [String: Any] {
                    out.append("tokenUsage keys: \(tu.keys.sorted().joined(separator: ", "))")
                }
            }
            let events = CursorUsageClient.parseEvents(body)
            let cents = events.reduce(0) { $0 + $1.cents }
            out.append("parsed \(events.count) events on page 1, $\(String(format: "%.2f", cents / 100))")
            var byModel: [String: Int] = [:]
            for e in events { byModel[e.model, default: 0] += 1 }
            out.append("models: \(byModel.map { "\($0.key)(\($0.value))" }.sorted().joined(separator: " "))")
            if status == 200 {
                let (all, complete) = try await client.fetchAll(since: UsageLedger.monthStart(now), until: now)
                if !complete { out.append("!! hit the page cap; month total below is incomplete") }
                let month = all.reduce(0) { $0 + $1.cents } / 100
                let today = all.filter { $0.at >= Calendar.current.startOfDay(for: now) }.reduce(0) { $0 + $1.cents } / 100
                out.append("this month: \(all.count) events, $\(String(format: "%.2f", month)); today: $\(String(format: "%.2f", today))")
                out.append(contentsOf: reconciliation(all, now: now))
                out.append(contentsOf: ChatCap.distribution(all, cap: GoldieConfig.load().chatCapUSD))
            }
        } catch {
            out.append("!! request failed: \(error)")
        }
        return out.joined(separator: "\n")
    }
}
