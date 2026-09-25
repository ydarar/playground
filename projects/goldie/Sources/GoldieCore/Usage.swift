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

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// This month's usage events, merged incrementally.
public struct UsageLedger {
    public private(set) var events: [UsageEvent] = []
    public private(set) var lastMergeAt: Date?

    public init() {}

    public var isEmpty: Bool { lastMergeAt == nil }

    public mutating func merge(_ new: [UsageEvent], now: Date) {
        let monthStart = Self.monthStart(now)
        var set = Set(events)
        set.formUnion(new)
        events = set.filter { $0.at >= monthStart }.sorted { $0.at < $1.at }
        lastMergeAt = now
    }

    /// Re-fetch a little overlap so late-arriving events aren't missed; duplicates merge away.
    public func fetchStart(now: Date) -> Date {
        let monthStart = Self.monthStart(now)
        guard lastMergeAt != nil, let last = events.last else { return monthStart }
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
            let events = Self.parseEvents(body)
            all += events
            if events.count < pageSize { return (all, true) }
        }
        return (all, false)
    }

    static func parseEvents(_ body: [String: Any]) -> [UsageEvent] {
        let list = (body["usageEventsDisplay"] as? [[String: Any]]) ?? (body["usageEvents"] as? [[String: Any]]) ?? []
        return list.compactMap { e -> UsageEvent? in
            guard let at = J.date(e["timestamp"]) else { return nil }
            let usage = e["tokenUsage"] as? [String: Any] ?? [:]
            let cents = J.number(usage["totalCents"]) ?? J.number(e["totalCents"]) ?? dollars(e["usageBasedCosts"]).map { $0 * 100 } ?? 0
            return UsageEvent(
                at: at,
                model: (e["model"] as? String) ?? "unknown",
                cents: cents,
                inputTokens: J.int(usage["inputTokens"]) ?? 0,
                outputTokens: J.int(usage["outputTokens"]) ?? 0,
                cacheReadTokens: J.int(usage["cacheReadTokens"]) ?? 0,
                cacheWriteTokens: J.int(usage["cacheWriteTokens"]) ?? 0
            )
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
    public static func enrich(_ snap: Snapshot, ledger: UsageLedger, config: GoldieConfig, now: Date) -> Snapshot {
        var out = snap
        guard !ledger.isEmpty else { return out }
        out.todayUSD = ledger.totalUSD(since: Calendar.current.startOfDay(for: now))
        out.monthUSD = ledger.totalUSD(since: UsageLedger.monthStart(now))

        let earliest = snap.threads.compactMap { $0.activityTimes.first }.min() ?? now
        let candidates = ledger.events.filter { $0.at >= earliest.addingTimeInterval(-config.attributionToleranceSeconds) }
        let assigned = attribute(candidates, to: snap.threads, tolerance: config.attributionToleranceSeconds)
        let rates = ledger.centsPerToken(now: now)

        for i in out.threads.indices {
            var t = out.threads[i]
            let events = assigned[t.id] ?? []
            if !events.isEmpty {
                t.spentUSD = events.reduce(0) { $0 + $1.cents } / 100
                if let lastUser = t.lastUserAt {
                    t.lastMessageUSD = events.filter { $0.at >= lastUser }.reduce(0) { $0 + $1.cents } / 100
                }
                let recent = events.suffix(3)
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

    /// Each event goes to the thread with the nearest activity timestamp (within tolerance).
    static func attribute(_ events: [UsageEvent], to threads: [ThreadSnapshot], tolerance: Double) -> [String: [UsageEvent]] {
        var out: [String: [UsageEvent]] = [:]
        for e in events {
            var best: (id: String, distance: Double)?
            for t in threads {
                guard let d = nearestDistance(e.at, in: t.activityTimes), d <= tolerance else { continue }
                if best == nil || d < best!.distance { best = (id: t.id, distance: d) }
            }
            if let best { out[best.id, default: []].append(e) }
        }
        return out
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
            if let fuzzy = rates.first(where: { $0.key != "*" && ($0.key.contains(name) || name.contains($0.key)) }) {
                return fuzzy.value
            }
        }
        return rates["*"]
    }
}

/// `goldiectl usage`: check the Cursor usage connection. Prints shapes and totals, never the token.
public enum UsageDiagnostics {
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
            }
        } catch {
            out.append("!! request failed: \(error)")
        }
        return out.joined(separator: "\n")
    }
}
