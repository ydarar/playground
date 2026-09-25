// Debug-only: release builds can't @testable import. Run with `swift run goldie-selftest`.
#if DEBUG
import Foundation
// Runs under goldie-selftest (Shim.swift provides XCTest-style assertions; no Xcode needed).
@testable import GoldieCore

final class GoldieCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(_ id: String = "a", ratio: Double, loop: Double = 0, running: Bool = true) -> ThreadSnapshot {
        ThreadSnapshot(id: id, title: "Fix auth", model: "grok", maxMode: false, userTurns: 3, messages: 20,
                       contextTokens: Int(ratio * 15_000), contextSource: "estimated", contextRatio: ratio,
                       nextTurnCostUSD: nil, toolCallsSinceUser: 0, maxRepeatCommand: 0, maxRepeatFileEdit: 0,
                       loopScore: loop, running: running, lastActivity: now)
    }

    private func snapshot(_ threads: [ThreadSnapshot], parallel: Int = 1) -> Snapshot {
        Snapshot(threads: threads, parallelCount: parallel, takenAt: now, cursorDBFound: true, hookEventsSeen: true)
    }

    func testRulesMoodBands() {
        let c = GoldieConfig()
        XCTAssertEqual(HeuristicBrain.judge(snapshot([]), config: c, snoozed: []).mood, .sleeping)
        XCTAssertEqual(HeuristicBrain.judge(snapshot([thread(ratio: 2)]), config: c, snoozed: []).mood, .working)
        XCTAssertEqual(HeuristicBrain.judge(snapshot([thread(ratio: 5)]), config: c, snoozed: []).mood, .heavy)
        XCTAssertEqual(HeuristicBrain.judge(snapshot([thread(ratio: 9)]), config: c, snoozed: []).mood, .alarmed)
        XCTAssertEqual(HeuristicBrain.judge(snapshot([thread(ratio: 1, loop: 0.8)]), config: c, snoozed: []).mood, .alarmed)
        XCTAssertEqual(HeuristicBrain.judge(snapshot([thread(ratio: 1)], parallel: 4), config: c, snoozed: []).mood, .alarmed)
    }

    func testRulesPickWorstThreadAndRespectSnooze() {
        let c = GoldieConfig()
        let snap = snapshot([thread("a", ratio: 5), thread("b", ratio: 6)])
        XCTAssertEqual(HeuristicBrain.judge(snap, config: c, snoozed: []).targetThread, "b")
        XCTAssertEqual(HeuristicBrain.judge(snap, config: c, snoozed: ["b"]).targetThread, "a")
    }

    func testLoopScore() {
        XCTAssertEqual(Signals.loopScore(toolCalls: 0, maxRepeatCommand: 0, maxRepeatFileEdit: 0), 0)
        XCTAssertEqual(Signals.loopScore(toolCalls: 40, maxRepeatCommand: 0, maxRepeatFileEdit: 0), 1)
        XCTAssertEqual(Signals.loopScore(toolCalls: 5, maxRepeatCommand: 5, maxRepeatFileEdit: 0), 1)
        XCTAssertEqual(Signals.loopScore(toolCalls: 5, maxRepeatCommand: 3, maxRepeatFileEdit: 0), 0.5)
    }

    func testSpeechBudgetAndAlarmFloor() {
        let judge = Judge(config: GoldieConfig())
        let snap = snapshot([thread(ratio: 5)])
        let rules = judge.heuristic(snap, now: now)
        XCTAssertTrue(judge.finalize(rules, heuristic: rules, snapshot: snap, now: now).speak)
        // Same nudge 1 minute later is suppressed by the cooldown.
        XCTAssertFalse(judge.finalize(rules, heuristic: rules, snapshot: snap, now: now.addingTimeInterval(60)).speak)

        // An LLM saying "working" can't hide an alarm.
        let alarmSnap = snapshot([thread(ratio: 12)])
        let alarm = judge.heuristic(alarmSnap, now: now)
        let calm = Verdict(mood: .working, speak: false, targetThread: nil, message: nil, reason: "fine", source: "llm")
        XCTAssertEqual(judge.finalize(calm, heuristic: alarm, snapshot: alarmSnap, now: now).mood, .alarmed)
    }

    func testCelebratesFreshStartAfterNudge() {
        let judge = Judge(config: GoldieConfig())
        let heavy = snapshot([thread("old", ratio: 5)])
        judge.observe(heavy, now: now)
        let rules = judge.heuristic(heavy, now: now)
        _ = judge.finalize(rules, heuristic: rules, snapshot: heavy, now: now)

        let fresh = snapshot([thread("old", ratio: 5), thread("new", ratio: 1)])
        let later = now.addingTimeInterval(120)
        judge.observe(fresh, now: later)
        let v = judge.finalize(judge.heuristic(fresh, now: later), heuristic: judge.heuristic(fresh, now: later), snapshot: fresh, now: later)
        XCTAssertEqual(v.mood, .celebrating)
    }

    func testBubbleParsingAndContextEstimate() {
        let user: [String: Any] = ["type": 1, "text": String(repeating: "a", count: 4000), "bubbleId": "x"]
        let tool: [String: Any] = [
            "type": 2, "text": "",
            "toolFormerData": ["name": "edit_file", "rawArgs": "{\"target_file\":\"src/a.ts\"}", "result": String(repeating: "b", count: 8000)],
        ]
        let bubbles = [user, tool].map(CursorStore.parseBubble)
        XCTAssertTrue(bubbles[0].isUser)
        XCTAssertTrue(bubbles[1].isTool && bubbles[1].isEdit)
        XCTAssertEqual(bubbles[1].filePath, "src/a.ts")

        let t = CursorThread(id: "a", title: "t", model: nil, maxMode: false, createdAt: nil, lastUpdatedAt: now,
                             reportedContextTokens: nil, bubbles: bubbles)
        let (tokens, source) = Signals.contextEstimate(t, config: GoldieConfig())
        XCTAssertEqual(source, "estimated")
        XCTAssertGreaterThan(tokens, 2500 + GoldieConfig().systemOverheadTokens)
    }

    func testHookTrackerRuns() {
        let tracker = HookTracker(file: URL(fileURLWithPath: "/dev/null"))
        let lines = [
            #"{"ts":1800000000,"event":"afterShellExecution","conversation_id":"c1","command":"npm test"}"#,
            #"{"ts":1800000001,"event":"afterShellExecution","conversation_id":"c1","command":"npm  test"}"#,
            #"{"ts":1800000002,"event":"afterFileEdit","conversation_id":"c1","file_path":"a.ts"}"#,
            #"{"ts":1800000003,"event":"stop","conversation_id":"c1","status":"completed"}"#,
        ].joined(separator: "\n") + "\n"
        tracker.ingest(Data(lines.utf8))
        let s = tracker.threads["c1"]
        XCTAssertEqual(s?.runToolEvents, 3)
        XCTAssertEqual(s?.runCommands["npm test"], 2)
        XCTAssertEqual(s?.running, false)
        XCTAssertEqual(s?.lastStatus, "completed")
    }

    func testPartialConfigMergesOverDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-test-\(UUID()).json")
        try Data(#"{"heavyRatio": 3, "llm": {"enabled": false}}"#.utf8).write(to: url)
        let c = GoldieConfig.load(from: url)
        XCTAssertEqual(c.heavyRatio, 3)
        XCTAssertFalse(c.llm.enabled)
        XCTAssertEqual(c.llm.endpoint, LLMConfig().endpoint)
        XCTAssertEqual(c.alarmedRatio, GoldieConfig().alarmedRatio)
    }

    func testHandoffDraft() {
        let bubbles = [
            CursorBubble(isUser: true, isTool: false, isEdit: false, text: "Make login use OAuth", toolName: nil, command: nil, filePath: nil, inputTokens: nil, createdAt: nil, textLength: 20),
            CursorBubble(isUser: false, isTool: true, isEdit: true, text: "", toolName: "edit_file", command: nil, filePath: "src/auth.ts", inputTokens: nil, createdAt: nil, textLength: 10),
            CursorBubble(isUser: false, isTool: false, isEdit: false, text: "Callback route added; tests failing on token refresh.", toolName: nil, command: nil, filePath: nil, inputTokens: nil, createdAt: nil, textLength: 50),
        ]
        let t = CursorThread(id: "a", title: "OAuth", model: "grok", maxMode: false, createdAt: nil, lastUpdatedAt: nil, reportedContextTokens: nil, bubbles: bubbles)
        let text = Handoff.draft(HandoffSource(thread: t))
        XCTAssertTrue(text.contains("Make login use OAuth"))
        XCTAssertTrue(text.contains("src/auth.ts"))
        XCTAssertTrue(text.contains("token refresh"))
    }

    func testLLMReplyParsing() {
        XCTAssertEqual(LLMBrain.stripThinking("<think>hmm</think>{\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(J.extractObject("sure! ```json\n{\"mood\":\"heavy\"}\n```")?["mood"] as? String, "heavy")
    }
    // MARK: Costs

    private func event(_ at: Date, cents: Double, model: String = "grok-4.7", tokens: Int = 100_000) -> UsageEvent {
        UsageEvent(at: at, model: model, cents: cents, inputTokens: 0, outputTokens: 0, cacheReadTokens: tokens, cacheWriteTokens: 0)
    }

    func testParseUsageEvents() {
        let body: [String: Any] = ["usageEventsDisplay": [
            ["timestamp": "1800000000000", "model": "grok-4.7",
             "tokenUsage": ["inputTokens": 10, "outputTokens": 5, "cacheReadTokens": 1000, "totalCents": 12.5]] as [String: Any],
            ["timestamp": "1800000060000", "model": "auto", "usageBasedCosts": "$0.30"],
        ]]
        let events = CursorUsageClient.parseEvents(body)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].cents, 12.5)
        XCTAssertEqual(events[0].totalTokens, 1015)
        XCTAssertEqual(events[1].cents, 30, accuracy: 0.001)
        XCTAssertEqual(events[0].at, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testJWTUserID() {
        // header.payload.signature with payload {"sub":"auth0|user_abc"}
        let payload = Data(#"{"sub":"auth0|user_abc"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CursorUsageClient.userID(fromJWT: "x.\(payload).y"), "user_abc")
    }

    func testCostAttributionByTime() {
        var a = thread("a", ratio: 5)
        a.activityTimes = [now.addingTimeInterval(-600), now.addingTimeInterval(-300)]
        a.lastUserAt = now.addingTimeInterval(-320)
        var b = thread("b", ratio: 1)
        b.activityTimes = [now.addingTimeInterval(-60)]

        var ledger = UsageLedger()
        ledger.merge([
            event(now.addingTimeInterval(-590), cents: 10),   // a
            event(now.addingTimeInterval(-290), cents: 20),   // a (after last user message)
            event(now.addingTimeInterval(-50), cents: 5),     // b
            event(now.addingTimeInterval(-3000), cents: 99),  // nobody nearby
        ], now: now)

        let enriched = CostModel.enrich(snapshot([a, b]), ledger: ledger, config: GoldieConfig(), now: now)
        let ea = enriched.threads[0]
        XCTAssertEqual(ea.spentUSD ?? 0, 0.30, accuracy: 0.0001)
        XCTAssertEqual(ea.lastMessageUSD ?? 0, 0.20, accuracy: 0.0001)
        XCTAssertEqual(ea.nextTurnCostUSD ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertEqual(ea.costSource, "cursor")
        XCTAssertEqual(enriched.threads[1].spentUSD ?? 0, 0.05, accuracy: 0.0001)
    }

    func testRateFallbackWhenNoEventsMatch() {
        var a = thread("a", ratio: 4)  // 60k tokens
        a.activityTimes = [now]
        var ledger = UsageLedger()
        ledger.merge([event(now.addingTimeInterval(-7200), cents: 10, tokens: 100_000)], now: now)  // 0.0001 c/token
        let t = CostModel.enrich(snapshot([a]), ledger: ledger, config: GoldieConfig(), now: now).threads[0]
        XCTAssertEqual(t.costSource, "cursor-rate")
        XCTAssertEqual(t.nextTurnCostUSD ?? 0, 0.06, accuracy: 0.0001)  // 60k × 0.0001¢ = 6¢
    }

    func testNearestDistance() {
        let times = [0.0, 100, 200].map { now.addingTimeInterval($0) }
        XCTAssertEqual(CostModel.nearestDistance(now.addingTimeInterval(130), in: times), 30)
        XCTAssertEqual(CostModel.nearestDistance(now.addingTimeInterval(-10), in: times), 10)
        XCTAssertEqual(CostModel.nearestDistance(now.addingTimeInterval(500), in: times), 300)
        XCTAssertNil(CostModel.nearestDistance(now, in: []))
    }

    // MARK: Budget

    func testStressedWhenMonthRunsHotButNoChatIsToBlame() {
        var snap = snapshot([thread(ratio: 1.5)])
        snap.projectedMonthUSD = 1200
        let v = HeuristicBrain.judge(snap, config: GoldieConfig(), snoozed: [])
        XCTAssertEqual(v.mood, .stressed)
        XCTAssertFalse(v.speak)

        // A heavy chat still wins: that's the actionable thing.
        var heavy = snapshot([thread(ratio: 5)])
        heavy.projectedMonthUSD = 1200
        XCTAssertEqual(HeuristicBrain.judge(heavy, config: GoldieConfig(), snoozed: []).mood, .heavy)
    }

    func testProjectionIsFilledFromLedger() {
        var ledger = UsageLedger()
        ledger.merge([event(now.addingTimeInterval(-60), cents: 1000)], now: now)
        let s = CostModel.enrich(snapshot([]), ledger: ledger, config: GoldieConfig(), now: now)
        XCTAssertEqual(s.monthUSD ?? 0, 10, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(s.projectedMonthUSD ?? 0, 10)
    }

    func testModelPolicyBlocksChineseVendors() {
        let k = ModelPolicy.defaultBlockedKeywords
        XCTAssertNotNil(ModelPolicy.blockedKeyword(for: "mlx-community/Qwen3-4B-Instruct-2507-4bit", keywords: k))
        XCTAssertNotNil(ModelPolicy.blockedKeyword(for: "deepseek-v3.1", keywords: k))
        XCTAssertNotNil(ModelPolicy.blockedKeyword(for: "kimi-k2", keywords: k))
        XCTAssertNil(ModelPolicy.blockedKeyword(for: "mlx-community/Llama-3.2-3B-Instruct-4bit", keywords: k))
        XCTAssertNil(ModelPolicy.blockedKeyword(for: "grok-4.7", keywords: k))
        XCTAssertNil(ModelPolicy.blockedKeyword(for: "claude-sonnet-5", keywords: k))
        XCTAssertNil(ModelPolicy.blockedKeyword(for: nil, keywords: k))
        XCTAssertEqual(GoldieConfig().llm.model, "mlx-community/Llama-3.2-3B-Instruct-4bit")
    }

    // MARK: Tasks & model fit

    private func bubble(user: Bool = false, text: String = "", at: Double, command: String? = nil,
                        edit: String? = nil, length: Int = 100) -> CursorBubble {
        CursorBubble(isUser: user, isTool: command != nil || edit != nil, isEdit: edit != nil, text: text,
                     toolName: edit != nil ? "edit_file" : (command != nil ? "run_terminal_cmd" : nil),
                     command: command, filePath: edit, inputTokens: nil,
                     createdAt: now.addingTimeInterval(at), textLength: length)
    }

    func testTaskKindClassification() {
        XCTAssertEqual(TaskKind.classify(text: "Fix the failing login test", edits: 2, commands: 3), .debugging)
        XCTAssertEqual(TaskKind.classify(text: "Rename UserService to AccountService", edits: 5, commands: 0), .refactor)
        XCTAssertEqual(TaskKind.classify(text: "How would you structure the cache?", edits: 0, commands: 0), .planning)
        XCTAssertEqual(TaskKind.classify(text: "Look through the payments module", edits: 0, commands: 0), .exploring)
        XCTAssertEqual(TaskKind.classify(text: "Add dark mode to settings", edits: 4, commands: 1), .feature)
    }

    func testSegmentsSplitOnUserMessagesAndDetectReask() {
        let bubbles = [
            bubble(user: true, text: "Fix the flaky upload test", at: -600),
            bubble(at: -590, command: "npm test"),
            bubble(at: -580, edit: "upload.ts"),
            bubble(at: -570, command: "npm test"),
            bubble(user: true, text: "still failing, try again", at: -500),
            bubble(at: -490, command: "npm test"),
        ]
        let segs = TaskSegmenter.segments(threadID: "a", model: "grok-4.7", bubbles: bubbles, running: true, now: now)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].kind, .debugging)
        XCTAssertEqual(segs[0].steps, 3)
        XCTAssertEqual(segs[0].maxRepeat, 2)
        XCTAssertTrue(segs[0].complete)
        XCTAssertTrue(segs[0].reasked)
        XCTAssertFalse(segs[1].complete)  // agent still running
    }

    private func task(_ model: String, kind: TaskKind = .debugging, cost: Double, troubled: Bool = false, i: Int) -> TaskSegment {
        TaskSegment(threadID: "\(model)-\(i)", model: model, kind: kind, start: now.addingTimeInterval(Double(-i * 600)),
                    end: now, steps: 10, maxRepeat: troubled ? 3 : 0, complete: true, reasked: false, costUSD: cost)
    }

    func testModelFitCanRecommendThePricierModel() {
        // Cheap model: $1/task but half its tasks loop → $2 per task that worked.
        // Pricier model: $1.40/task, no loops → $1.40. Recommend the pricier one.
        var tasks: [TaskSegment] = []
        for i in 0..<6 { tasks.append(task("cheap-model", cost: 1.0, troubled: i % 2 == 0, i: i)) }
        for i in 0..<6 { tasks.append(task("strong-model", cost: 1.4, i: i + 10)) }
        let stats = ModelFit.stats(tasks, since: now.addingTimeInterval(-86400 * 30))
        let advice = ModelFit.advice(kind: .debugging, model: "cheap-model", stats: stats)
        XCTAssertNotNil(advice)
        XCTAssertTrue(advice?.contains("strong-model") ?? false)
        XCTAssertNil(ModelFit.advice(kind: .debugging, model: "strong-model", stats: stats))
    }

    func testModelFitStaysQuietWithoutEvidence() {
        var tasks: [TaskSegment] = []
        for i in 0..<6 { tasks.append(task("a-model", cost: 2.0, i: i)) }
        for i in 0..<3 { tasks.append(task("b-model", cost: 0.5, i: i + 10)) }  // too few tasks
        let stats = ModelFit.stats(tasks, since: now.addingTimeInterval(-86400 * 30))
        XCTAssertNil(ModelFit.advice(kind: .debugging, model: "a-model", stats: stats))
        // Different kind of work: no cross-kind advice.
        XCTAssertNil(ModelFit.advice(kind: .refactor, model: "a-model", stats: stats))
    }

    func testTaskStorePersistsFinishedPricedTasks() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-tasks-\(UUID()).jsonl")
        let store = TaskStore(file: url)
        var unfinished = task("m", cost: 1, i: 1)
        unfinished.complete = false
        var unpriced = task("m", cost: 1, i: 2)
        unpriced.costUSD = nil
        store.record([task("m", cost: 1, i: 0), unfinished, unpriced], now: now)
        store.save(now: now)
        XCTAssertEqual(TaskStore(file: url).all.count, 1)
    }

    func testBloatDetection() {
        let bubbles = [
            bubble(user: true, text: "read the log", at: -100),
            CursorBubble(isUser: false, isTool: true, isEdit: false, text: "", toolName: "read_file", command: nil,
                         filePath: "/tmp/server.log", inputTokens: nil, createdAt: now, textLength: 90_000,
                         resultLength: 80_000),
        ]
        let t = CursorThread(id: "a", title: "t", model: "grok-4.7", maxMode: false, createdAt: nil, lastUpdatedAt: now,
                             reportedContextTokens: nil, bubbles: bubbles)
        let snap = Signals.build(id: "a", thread: t, hook: nil, config: GoldieConfig(), now: now)
        XCTAssertEqual(snap.bloatLabel, "server.log")
        XCTAssertEqual(snap.bloatTokens, 20_000)
    }

    func testTaskStoreKeepsModelAndNeverLowersCost() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-tasks-\(UUID()).jsonl")
        let store = TaskStore(file: url)
        let original = task("grok-4.7", cost: 2.0, i: 0)
        store.record([original], now: now)

        var later = original
        later.model = "other-model"  // chat switched models afterwards
        later.costUSD = 0.5          // only part of its charges still in the matching window
        store.record([later], now: now)
        XCTAssertEqual(store.tasks[original.id]?.model, "grok-4.7")
        XCTAssertEqual(store.tasks[original.id]?.costUSD, 2.0)

        later.costUSD = 2.3          // a late charge arrived
        store.record([later], now: now)
        XCTAssertEqual(store.tasks[original.id]?.costUSD, 2.3)

        var ancient = task("x", cost: 1, i: 1)
        ancient.end = now.addingTimeInterval(-5 * 3600)  // Goldie didn't see this one happen
        store.record([ancient], now: now)
        XCTAssertNil(store.tasks[ancient.id])
    }

    // MARK: Guards, handoff files, installer

    private func ev(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["event": event, "conversation_id": "c1", "ts": now.timeIntervalSince1970]
        for (k, v) in extra { e[k] = v }
        return e
    }

    func testLoopGuardBlocksRepeatsOnlyWithoutEdits() {
        var config = GuardConfig()
        config.loopGuard = true
        config.loopRepeatLimit = 3
        let payload: [String: Any] = ["conversation_id": "c1", "command": "npm  test"]
        let runs = Array(repeating: ev("afterShellExecution", ["command": "npm test"]), count: 3)

        let blocked = Guards.decide(event: Guards.shellEvent, payload: payload, config: config, recent: runs, now: now)
        XCTAssertEqual(blocked?.output["permission"] as? String, "deny")
        XCTAssertEqual(blocked?.denied?["event"] as? String, "guardDenyShell")

        // An edit in between means the agent changed something: not a loop.
        let withEdit = [runs[0], runs[1], ev("afterFileEdit", ["file_path": "a.ts"]), runs[2]]
        // "No opinion" is an empty reply, so Cursor's own approval rules still apply.
        XCTAssertNil(Guards.decide(event: Guards.shellEvent, payload: payload, config: config, recent: withEdit, now: now)?
            .output["permission"])

        // Guard off: always allow.
        XCTAssertNil(Guards.decide(event: Guards.shellEvent, payload: payload, config: GuardConfig(), recent: runs, now: now)?
            .output["permission"])
    }

    func testReadGuardDeniesOnceThenAllowsRetry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-big-\(UUID()).log")
        try Data(repeating: 65, count: 300 * 1024).write(to: url)
        var config = GuardConfig()
        config.readGuard = true
        let payload: [String: Any] = ["conversation_id": "c1", "file_path": url.path]

        let first = Guards.decide(event: Guards.readEvent, payload: payload, config: config, recent: [], now: now)
        XCTAssertEqual(first?.output["permission"] as? String, "deny")
        let denied = try XCTUnwrap(first?.denied)
        let retry = Guards.decide(event: Guards.readEvent, payload: payload, config: config, recent: [denied], now: now)
        XCTAssertNotNil(retry)
        XCTAssertNil(retry?.output["permission"])
    }

    func testHandoffWriterSavesInRepoAndExcludesFromGit() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-repo-\(UUID())")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let saved = try XCTUnwrap(HandoffWriter.write("## Goal\nx", title: "Browser notifications Spike!", workspace: repo.path, now: now))
        XCTAssertTrue(saved.relativePath.hasPrefix(".goldie/handoffs/browser-notifications-spike-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
        let exclude = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertTrue(exclude.contains(".goldie/"))
        // Second write doesn't duplicate the exclude line.
        _ = HandoffWriter.write("x", title: "t", workspace: repo.path, now: now)
        let again = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertEqual(again.components(separatedBy: ".goldie/").count - 1, 1)
        XCTAssertNil(HandoffWriter.write("x", title: "t", workspace: nil, now: now))
    }

    func testInstallerAddsGuardHooksOnlyWhenAskedAndKeepsUserHooks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-hooks-\(UUID()).json")
        try Data(#"{"version":1,"hooks":{"beforeShellExecution":[{"command":"./mine.sh"}]}}"#.utf8).write(to: file)
        _ = try CursorHooksInstaller.install(executable: "/x/goldiectl", guards: false, hooksFile: file)
        var hooks = try XCTUnwrap(J.obj(Data(contentsOf: file))?["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.count, 1)  // only the user's own
        XCTAssertNil(hooks["beforeReadFile"])
        XCTAssertNotNil(hooks["stop"])

        _ = try CursorHooksInstaller.install(executable: "/x/goldiectl", guards: true, hooksFile: file)
        hooks = try XCTUnwrap(J.obj(Data(contentsOf: file))?["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((hooks["beforeReadFile"] as? [[String: Any]])?.count, 1)
    }

    func testHookReplyFailsOpen() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("goldie-events-\(UUID()).jsonl")
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).json")
        let reply = HookRecorder.handle(stdin: Data("not json".utf8), eventArg: Guards.shellEvent, file: file, configURL: config, now: now)
        XCTAssertEqual(reply, "{}")  // never auto-approves
        XCTAssertEqual(HookRecorder.handle(stdin: Data(), eventArg: "stop", file: file, configURL: config, now: now), "{}")
    }

    // MARK: Integration-report fixes

    func testConversationIdAttributionIsExactAndNeverGuessed() {
        var a = thread("a", ratio: 5)
        a.activityTimes = [now.addingTimeInterval(-60)]
        var b = thread("b", ratio: 1)
        b.activityTimes = [now.addingTimeInterval(-60)]  // same moment: time matching couldn't tell them apart

        var forB = event(now.addingTimeInterval(-55), cents: 40, model: "grok-4.7-high-fast")
        forB.conversationId = "b"
        var otherChat = event(now.addingTimeInterval(-58), cents: 99)
        otherChat.conversationId = "someone-else"  // a chat Goldie isn't watching
        var ledger = UsageLedger()
        ledger.merge([forB, otherChat], now: now)

        let s = CostModel.enrich(snapshot([a, b]), ledger: ledger, config: GoldieConfig(), now: now)
        XCTAssertNil(s.threads[0].spentUSD)
        XCTAssertEqual(s.threads[1].spentUSD ?? 0, 0.40, accuracy: 0.0001)
        XCTAssertEqual(s.threads[1].billedModel, "grok-4.7-high-fast")
        XCTAssertEqual(s.threads[1].effectiveModel, "grok-4.7-high-fast")
    }

    func testTaskModelComesFromBilledEvents() {
        var a = thread("a", ratio: 3)
        a.activityTimes = [now.addingTimeInterval(-100)]
        a.tasks = [TaskSegment(threadID: "a", model: "grok-4.7", kind: .debugging, start: now.addingTimeInterval(-120),
                               end: now.addingTimeInterval(-60), steps: 2, maxRepeat: 0, complete: true, reasked: false, costUSD: nil)]
        var e1 = event(now.addingTimeInterval(-100), cents: 10, model: "grok-4.7-high")
        e1.conversationId = "a"
        var e2 = event(now.addingTimeInterval(-90), cents: 10, model: "grok-4.7-high")
        e2.conversationId = "a"
        var ledger = UsageLedger()
        ledger.merge([e1, e2], now: now)
        let t = CostModel.enrich(snapshot([a]), ledger: ledger, config: GoldieConfig(), now: now).threads[0]
        XCTAssertEqual(t.tasks[0].model, "grok-4.7-high")
        XCTAssertEqual(t.tasks[0].costUSD ?? 0, 0.20, accuracy: 0.0001)
    }

    func testUsageEventReconciliationFields() {
        let body: [String: Any] = ["usageEventsDisplay": [
            ["timestamp": "1800000000000", "model": "grok-4.7-high", "conversationId": "c9", "isChargeable": false,
             "chargedCents": 5, "tokenUsage": ["totalCents": 10, "enterpriseUsageDiscountPercent": 7]] as [String: Any],
        ]]
        let e = CursorUsageClient.parseEvents(body)[0]
        XCTAssertEqual(e.conversationId, "c9")
        XCTAssertFalse(e.chargeable)
        XCTAssertEqual(e.chargedCents, 5)
        XCTAssertEqual(e.discountPercent, 7)
        XCTAssertEqual(e.cents, 10)  // Goldie's total stays raw until the dashboard comparison picks a formula
        let lines = UsageDiagnostics.reconciliation([e], now: now).joined(separator: "\n")
        XCTAssertTrue(lines.contains("$0.10"))   // A raw
        XCTAssertTrue(lines.contains("$0.09"))   // B after 7% discount (9.3¢)
        XCTAssertTrue(lines.contains("7.00%"))
    }

    func testBigReadIgnoresScreenshots() {
        let shot = CursorStore.parseBubble(["type": 2, "toolFormerData": [
            "name": "mcp-cursor-ide-browser-browser_take_screenshot",
            "result": "data:image/png;base64," + String(repeating: "A", count: 200_000)]])
        let file = CursorStore.parseBubble(["type": 2, "toolFormerData": [
            "name": "read_file_v2", "rawArgs": #"{"path":"/tmp/goldie-big.txt"}"#,
            "result": String(repeating: "x", count: 60_000)]])
        XCTAssertTrue(shot.resultIsImage)
        XCTAssertFalse(file.resultIsImage)
        let t = CursorThread(id: "a", title: "t", model: nil, maxMode: false, createdAt: nil, lastUpdatedAt: now,
                             reportedContextTokens: nil, bubbles: [shot, file])
        let snap = Signals.build(id: "a", thread: t, hook: nil, config: GoldieConfig(), now: now)
        XCTAssertEqual(snap.bloatLabel, "goldie-big.txt")
    }

    func testLedgerKeepsNewestCopyOfARefetchedEvent() {
        var first = event(now.addingTimeInterval(-60), cents: 10)
        first.conversationId = "c1"
        var updated = first
        updated.chargedCents = 9  // Cursor updated the charge between fetches
        var ledger = UsageLedger()
        ledger.merge([first], now: now)
        ledger.merge([updated], now: now)
        XCTAssertEqual(ledger.events.count, 1)
        XCTAssertEqual(ledger.events.first?.chargedCents, 9)
    }

    func testProbeHidesPathLikeKeys() {
        XCTAssertEqual(CursorProbe.describe(["file:///Users/me/secret.swift": 1]), "object(1 keys, names hidden)")
        XCTAssertEqual(CursorProbe.describe(["modelName": "x", "maxMode": 0] as [String: Any]), "object{maxMode,modelName}")
    }
}
#endif
