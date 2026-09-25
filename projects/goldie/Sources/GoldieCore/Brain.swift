import Foundation

public enum Mood: String, Codable, CaseIterable {
    case sleeping, working, heavy, alarmed, stressed, celebrating

    var severity: Int {
        switch self {
        case .alarmed: return 3
        case .stressed, .heavy: return 2
        case .working, .celebrating: return 1
        case .sleeping: return 0
        }
    }
}

public struct Verdict: Codable, Equatable {
    public var mood: Mood
    /// Show a speech bubble now (subject to the speech budget in `Judge.finalize`).
    public var speak: Bool
    public var targetThread: String?
    public var message: String?
    public var reason: String
    /// "llm" or "rules"
    public var source: String

    public init(mood: Mood, speak: Bool, targetThread: String?, message: String?, reason: String, source: String) {
        self.mood = mood
        self.speak = speak
        self.targetThread = targetThread
        self.message = message
        self.reason = reason
        self.source = source
    }

    public static let sleeping = Verdict(mood: .sleeping, speak: false, targetThread: nil, message: nil,
                                         reason: "No active Cursor agent threads.", source: "rules")
}

/// Deterministic fallback brain, and the safety floor under the LLM brain.
public enum HeuristicBrain {
    public static func judge(_ snap: Snapshot, config: GoldieConfig, snoozed: Set<String>) -> Verdict {
        if snap.threads.isEmpty { return .sleeping }

        if snap.parallelCount >= config.parallelAlarm {
            return Verdict(mood: .alarmed, speak: true, targetThread: nil,
                           message: "\(snap.parallelCount) fish burning at once",
                           reason: "\(snap.parallelCount) chats are running at once, and each one pays to re-read its own history every step.",
                           source: "rules")
        }

        var best: (thread: ThreadSnapshot, mood: Mood, message: String?, reason: String)?
        for t in snap.threads where !snoozed.contains(t.id) {
            let a = assess(t, config: config)
            if let current = best {
                let better = a.mood.severity > current.mood.severity
                    || (a.mood.severity == current.mood.severity && t.contextRatio > current.thread.contextRatio)
                if !better { continue }
            }
            best = (thread: t, mood: a.mood, message: a.message, reason: a.reason)
        }
        guard let winner = best else {
            return Verdict(mood: .working, speak: false, targetThread: nil, message: nil,
                           reason: "Only snoozed threads are active.", source: "rules")
        }
        let nudging = winner.mood == .heavy || winner.mood == .alarmed
        if !nudging, let projected = snap.projectedMonthUSD, projected > config.monthlyBudgetUSD * 1.05 {
            // No single chat to blame, but the month is running hot: show it, don't say it.
            return Verdict(mood: .stressed, speak: false, targetThread: nil, message: nil,
                           reason: String(format: "Chats look fine, but at this pace Cursor reaches ~$%.0f this month (budget $%.0f).",
                                          projected, config.monthlyBudgetUSD),
                           source: "rules")
        }
        return Verdict(mood: winner.mood, speak: nudging, targetThread: nudging ? winner.thread.id : nil,
                       message: winner.message, reason: winner.reason, source: "rules")
    }

    static func assess(_ t: ThreadSnapshot, config: GoldieConfig) -> (mood: Mood, message: String?, reason: String) {
        let name = "“\(t.title.clipped(40))”"
        let k = t.contextTokens / 1000
        let perStep = t.nextTurnCostUSD.map { String(format: " (~$%.2f per step)", $0) } ?? ""
        let cheaper = max(1, Int(t.contextRatio.rounded()))
        let mode = t.maxMode ? " in Max Mode" : ""

        if t.loopScore >= 0.75 {
            var why = "\(t.toolCallsSinceUser) steps since your last message"
            if t.maxRepeatCommand >= 3 { why = "ran the same command \(t.maxRepeatCommand)× in a row" }
            else if t.maxRepeatFileEdit >= 4 { why = "edited the same file \(t.maxRepeatFileEdit)×" }
            return (.alarmed, "going in circles. fresh water?",
                    "\(name) looks stuck: \(why), and every step re-reads \(k)k tokens\(perStep).")
        }
        if t.contextRatio >= config.alarmedRatio {
            return (.alarmed, "this bowl's murky. fresh water?",
                    "\(name) re-reads \(k)k tokens every step\(mode)\(perStep). A new chat would be ~\(cheaper)× cheaper per step.")
        }
        if t.contextRatio >= config.heavyRatio || t.loopScore >= 0.5 || (t.maxMode && t.contextRatio >= config.heavyRatio * 0.75) {
            return (.heavy, "fresh water?",
                    "\(name) is getting long: \(k)k tokens every step\(mode)\(perStep). A new chat would be ~\(cheaper)× cheaper.")
        }
        return (.working, nil, "\(name) is fine: \(k)k tokens per step\(perStep).")
    }
}

public struct NudgeRecord: Codable, Equatable {
    public var at: Date
    public var thread: String
    public var message: String
    public var feedback: String?
}

public struct JudgeContext {
    public var snapshot: Snapshot
    public var heuristic: Verdict
    public var nudges: [NudgeRecord]
    public var snoozed: Set<String>
    public var now: Date
}

/// Owns the non-negotiable guardrails around whichever brain proposed a verdict:
/// speech budget, snoozes, "alarms can't be hidden", and the celebration moment.
public final class Judge {
    public let config: GoldieConfig
    public private(set) var nudges: [NudgeRecord] = []
    private var snoozedUntil: [String: Date] = [:]
    private var lastSpokeAt: [String: Date] = [:]
    private var knownThreads: Set<String> = []
    private var primed = false
    private var celebrateUntil = Date.distantPast

    public init(config: GoldieConfig) {
        self.config = config
    }

    public func snoozed(now: Date) -> Set<String> {
        Set(snoozedUntil.filter { $0.value > now }.keys)
    }

    public func isSnoozed(_ thread: String, now: Date) -> Bool {
        (snoozedUntil[thread] ?? .distantPast) > now
    }

    /// Spot "you started fresh after a nudge" → celebrate.
    public func observe(_ snap: Snapshot, now: Date) {
        let ids = Set(snap.threads.map(\.id))
        if primed {
            let fresh = ids.subtracting(knownThreads)
            if !fresh.isEmpty, let last = nudges.last, now.timeIntervalSince(last.at) < 15 * 60, !fresh.contains(last.thread) {
                celebrateUntil = now.addingTimeInterval(30)
                recordFeedback(thread: last.thread, feedback: "started a fresh thread")
            }
        }
        knownThreads.formUnion(ids)
        primed = true
    }

    public func heuristic(_ snap: Snapshot, now: Date) -> Verdict {
        HeuristicBrain.judge(snap, config: config, snoozed: snoozed(now: now))
    }

    public func context(for snap: Snapshot, heuristic: Verdict, now: Date) -> JudgeContext {
        JudgeContext(snapshot: snap, heuristic: heuristic, nudges: Array(nudges.suffix(6)), snoozed: snoozed(now: now), now: now)
    }

    public func finalize(_ proposed: Verdict, heuristic: Verdict, snapshot: Snapshot, now: Date) -> Verdict {
        if snapshot.threads.isEmpty { return .sleeping }
        var v = proposed
        if heuristic.mood == .alarmed && v.mood != .alarmed { v = heuristic }  // the brain can't hide alarms
        if v.mood == .sleeping { v.mood = .working }  // threads are active, so not asleep
        if let target = v.targetThread, snapshot.thread(target) == nil { v.targetThread = nil }
        if now < celebrateUntil {
            v.mood = .celebrating
            v.speak = false
            return v
        }
        if let target = v.targetThread, isSnoozed(target, now: now) { v.speak = false }
        if v.speak {
            let key = v.targetThread ?? "_global"
            let cooldown = (v.mood == .alarmed ? 5 : config.speechCooldownMinutes) * 60
            if v.message?.isEmpty ?? true {
                v.speak = false
            } else if let last = lastSpokeAt[key], now.timeIntervalSince(last) < cooldown {
                v.speak = false
            } else {
                lastSpokeAt[key] = now
                nudges.append(NudgeRecord(at: now, thread: key, message: v.message ?? "", feedback: nil))
                if nudges.count > 30 { nudges.removeFirst(nudges.count - 30) }
            }
        }
        return v
    }

    public func snooze(thread: String, now: Date, minutes: Double? = nil) {
        snoozedUntil[thread] = now.addingTimeInterval((minutes ?? config.snoozeMinutes) * 60)
        recordFeedback(thread: thread, feedback: "snoozed")
    }

    public func notHelpful(thread: String, now: Date) {
        snoozedUntil[thread] = now.addingTimeInterval(120 * 60)
        recordFeedback(thread: thread, feedback: "not helpful")
    }

    public func recordFeedback(thread: String, feedback: String) {
        if let i = nudges.lastIndex(where: { $0.thread == thread }) { nudges[i].feedback = feedback }
    }

    /// Coarse state; the LLM is re-asked when this changes (or on a timer).
    public static func fingerprint(_ snap: Snapshot) -> String {
        let parts = snap.threads.map { t in
            "\(t.id.prefix(8)):\(Int(t.contextRatio)):\(Int(t.loopScore * 4)):\(t.running ? 1 : 0)"
        }
        return parts.sorted().joined(separator: ",") + "|p\(snap.parallelCount)"
    }
}
