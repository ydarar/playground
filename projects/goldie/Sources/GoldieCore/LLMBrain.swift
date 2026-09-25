import Foundation

/// The "intelligent" brain: a small local model (MLX via `mlx_lm.server`, or any
/// OpenAI-compatible endpoint). It only ever sees the numeric snapshot, never transcripts,
/// except when writing a handoff, and that never leaves the Mac.
public final class LLMBrain {
    public let config: LLMConfig

    public init(config: LLMConfig) {
        self.config = config
    }

    // MARK: Judging

    static let judgeSystem = """
    You are the judgment core of Goldie, a mostly-silent goldfish desktop mascot that helps one developer \
    cut AI coding-agent spend by ~25x.

    Key fact: agent threads are stateless, so every turn re-sends the whole context. Per-turn cost grows with \
    context size, and a thread's total cost grows roughly with the square of its length. Starting a fresh \
    thread with a short handoff is often far cheaper than one more turn in a bloated thread.

    One user message can trigger many agent "steps" (model calls), and every step re-reads the whole chat.

    You get a JSON snapshot of live Cursor agent threads:
    - context_tokens: tokens re-read on every step; context_ratio: how many times cheaper a step would be in a new chat
    - cost_per_step_usd, last_message_usd, spent_usd: real dollars from Cursor usage when present
    - loop signals: steps_since_user_message, max_repeat_command, max_repeat_file_edit, loop_score (0-1)
    - running, minutes_idle, model, max_mode, parallel_threads, today_usd, month_usd, projected_month_usd \
    (monthly budget: budget_usd; "stressed" = month on pace to exceed it with no single chat to blame)
    - current_task_kind, biggest_single_read_tokens (one huge file/log re-sent every step)
    - model_fit_tip: evidence from the user's OWN history of cost per finished task by kind of work.
      Never suggest switching models unless model_fit_tip is present; a cheaper-per-token model can cost
      more per task. Only relay the tip when the chat is doing that kind of work.
    plus a rules-based suggestion and recent nudges with the user's feedback.

    Each thread has a "situation" computed from hard signals:
    - redirect: it's repeating itself. Suggest a redirect, not a new chat.
    - fresh_now: heavy AND waiting for the user. The right moment to start the next task in a fresh chat.
    - finish_then_fresh: heavy but mid-task. Don't interrupt: a new chat would re-pay to rediscover everything.
    - idle_heavy: heavy but idle, costing nothing. Don't nudge.
    - fine: nothing to do.

    Decide Goldie's mood and whether it should speak. Guidance:
    - Only speak for redirect or fresh_now situations.
    - Stay quiet unless acting now clearly saves money. Silence is the default.
    - A thread still converging (few repeats, recently asked by the user) can run a bit longer.
    - Circling (same command or file again and again) or a very high context_ratio: nudge to start fresh.
    - Many threads running in parallel multiplies spend.
    - Respect feedback: after "not helpful" or "snoozed", don't repeat the same nudge soon.

    Reply with ONLY a JSON object:
    {"mood": "sleeping|working|heavy|alarmed|stressed|celebrating", "speak": true|false, \
    "target_thread": "<thread id like t1>" or null, "message": "<max 8 lowercase words>" or null, \
    "reason": "<one short plain-English sentence for a non-expert, with $ amounts when known; \
    never say 'context_ratio' or 'loop_score'>"}
    """

    public func judge(_ ctx: JudgeContext) async -> Verdict? {
        let (payload, idMap) = Self.payload(ctx)
        guard let text = try? await complete(system: Self.judgeSystem, user: payload, maxTokens: 220),
              let obj = J.extractObject(text),
              let moodRaw = obj["mood"] as? String,
              let mood = Mood(rawValue: moodRaw.lowercased().trimmingCharacters(in: .whitespaces)) else { return nil }
        let target = (obj["target_thread"] as? String).flatMap { idMap[$0] }
        let message = (obj["message"] as? String).map { $0.clipped(60) }
        return Verdict(mood: mood,
                       speak: (obj["speak"] as? Bool) ?? false,
                       targetThread: target,
                       message: message,
                       reason: ((obj["reason"] as? String) ?? "").clipped(200),
                       source: "llm")
    }

    /// Compact JSON with short ids (t1, t2…) so a small model can reference threads reliably.
    static func payload(_ ctx: JudgeContext) -> (String, [String: String]) {
        var idMap: [String: String] = [:]
        var reverse: [String: String] = [:]
        var threads: [[String: Any]] = []
        for (i, t) in ctx.snapshot.threads.enumerated() {
            let short = "t\(i + 1)"
            idMap[short] = t.id
            reverse[t.id] = short
            var d: [String: Any] = [
                "id": short,
                "title": t.title.clipped(60),
                "model": t.effectiveModel ?? "unknown",
                "max_mode": t.maxMode,
                "context_tokens": t.contextTokens,
                "context_source": t.contextSource,
                "context_ratio": (t.contextRatio * 10).rounded() / 10,
                "user_turns": t.userTurns,
                "steps_since_user_message": t.toolCallsSinceUser,
                "max_repeat_command": t.maxRepeatCommand,
                "max_repeat_file_edit": t.maxRepeatFileEdit,
                "loop_score": (t.loopScore * 100).rounded() / 100,
                "running": t.running,
                "minutes_idle": Int(ctx.now.timeIntervalSince(t.lastActivity) / 60),
                "snoozed": ctx.snoozed.contains(t.id),
                "situation": Self.situationName(t.advice(config: ctx.config, now: ctx.now)),
            ]
            if let cost = t.nextTurnCostUSD { d["cost_per_step_usd"] = (cost * 1000).rounded() / 1000 }
            if let spent = t.spentUSD { d["spent_usd"] = (spent * 100).rounded() / 100 }
            if let last = t.lastMessageUSD { d["last_message_usd"] = (last * 100).rounded() / 100 }
            if let kind = t.currentKind {
                d["current_task_kind"] = kind.rawValue
                if let tip = ModelFit.advice(kind: kind, model: t.effectiveModel, stats: ctx.modelStats) { d["model_fit_tip"] = tip }
            }
            if t.bloatTokens > 0 { d["biggest_single_read_tokens"] = t.bloatTokens }
            threads.append(d)
        }
        let nudges: [[String: Any]] = ctx.nudges.map { n in
            [
                "minutes_ago": Int(ctx.now.timeIntervalSince(n.at) / 60),
                "thread": reverse[n.thread] ?? n.thread,
                "message": n.message,
                "feedback": n.feedback ?? "none yet",
            ]
        }
        var rules: [String: Any] = ["mood": ctx.heuristic.mood.rawValue, "reason": ctx.heuristic.reason]
        if let target = ctx.heuristic.targetThread, let short = reverse[target] {
            rules["target_thread"] = short
        } else {
            rules["target_thread"] = NSNull()
        }
        var root: [String: Any] = [
            "threads": threads,
            "parallel_threads": ctx.snapshot.parallelCount,
            "rules_suggestion": rules,
            "recent_nudges": nudges,
        ]
        if let today = ctx.snapshot.todayUSD { root["today_usd"] = (today * 100).rounded() / 100 }
        if let month = ctx.snapshot.monthUSD { root["month_usd"] = (month * 100).rounded() / 100 }
        if let projected = ctx.snapshot.projectedMonthUSD { root["projected_month_usd"] = projected.rounded() }
        root["budget_usd"] = ctx.budgetUSD
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}", idMap)
    }

    static func situationName(_ advice: ChatAdvice) -> String {
        switch advice {
        case .fine: return "fine"
        case .redirect: return "redirect"
        case .freshNow: return "fresh_now"
        case .finishThenFresh: return "finish_then_fresh"
        case .idleHeavy: return "idle_heavy"
        }
    }

    // MARK: Handoff

    static let handoffSystem = """
    Rewrite the notes below into a crisp opening prompt (max 300 words) for a brand-new coding-agent thread \
    that continues the same work. Keep: the goal, where things stand, the files that matter, the next concrete \
    step, and anything NOT to redo. Tell the agent to avoid re-reading files it doesn't need. \
    Output only the prompt text.
    """

    public func refineHandoff(_ draft: String) async -> String? {
        guard let text = try? await complete(system: Self.handoffSystem, user: draft, maxTokens: 600) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? trimmed : nil
    }

    // MARK: Transport

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: config.endpoint) else { throw GoldieError("bad LLM endpoint") }
        var request = URLRequest(url: url, timeoutInterval: config.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GoldieError("LLM HTTP error") }
        guard let obj = J.obj(data),
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw GoldieError("LLM reply not understood") }
        return Self.stripThinking(content)
    }

    static func stripThinking(_ s: String) -> String {
        guard let open = s.range(of: "<think>") else { return s }
        guard let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) else {
            return String(s[..<open.lowerBound])
        }
        return String(s[..<open.lowerBound]) + String(s[close.upperBound...])
    }
}
