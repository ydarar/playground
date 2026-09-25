import AppKit
import GoldieCore
import SwiftUI

struct Speech: Equatable {
    var text: String
    var thread: String?
    var until: Date
}

/// Visual encodings for the bowl (see PRD §4 "The bowl is the dashboard").
struct BowlState: Equatable {
    var mood: Mood = .sleeping
    /// Share of the monthly budget left (full until costs are known).
    var waterLevel: Double = 1
    /// 0 = clear, 1 = murky. Driven by the worst thread's context ratio.
    var murk: Double = 0
    /// Goldie bloats with the target (or worst) thread's per-turn cost.
    var puff: Double = 1
    /// One small fish per extra agent running in parallel.
    var fryCount: Int = 0
}

@MainActor
final class GoldieEngine: ObservableObject {
    @Published private(set) var snapshot = Snapshot.empty
    @Published private(set) var verdict = Verdict.sleeping
    @Published private(set) var speech: Speech?
    @Published private(set) var toast: String?
    @Published private(set) var brainStatus = "rules"
    @Published private(set) var usageStatus = "not connected"
    @Published var expanded = false {
        didSet { if !expanded { selectedThread = nil } }  // selection lives only while the card is open
    }
    /// A chat you clicked in the card. Fresh bowl, Start fresh and Goldie's puff follow it.
    @Published var selectedThread: String?
    /// Animations pause while the panel is hidden.
    @Published var panelVisible = true
    /// Bowl diameter in points (Small 130 / Medium 170 / Large 210), remembered across launches.
    @Published var bowlSize: Double = GoldieEngine.savedBowlSize() {
        didSet { UserDefaults.standard.set(bowlSize, forKey: "goldie.bowlSize") }
    }

    nonisolated private static func savedBowlSize() -> Double {
        let v = UserDefaults.standard.double(forKey: "goldie.bowlSize")
        return v >= 100 ? v : 170
    }

    private(set) var config: GoldieConfig
    private let collector: SnapshotCollector
    private let judge: Judge
    private let llm: LLMBrain?
    private let queue = DispatchQueue(label: "goldie.collector", qos: .utility)
    private var timer: Timer?

    private var llmInFlight = false
    private var llmHealthy = false
    private var lastLLMAt = Date.distantPast
    private var lastFingerprint = ""
    private var llmVerdict: (verdict: Verdict, fingerprint: String, at: Date)?

    /// Finished tasks with their cost, kept on disk: the evidence behind model advice.
    private let taskStore = TaskStore()
    /// Cost per finished task by model and kind of work (last 30 days).
    @Published private(set) var modelStats: [ModelStats] = []
    /// Account-wide advice (e.g. every chat starts heavy because of rules/MCP setup).
    @Published private(set) var setupTip: String?
    private var startTokensSeen: [String: Int] = [:]
    /// Suggestions you closed this session.
    @Published private(set) var dismissedSuggestions: Set<String> = []
    private var guardBlocksSeen: [String: Int] = [:]

    /// Collector output before costs are attached.
    private var rawSnapshot = Snapshot.empty
    private var ledger = UsageLedger()
    private let usageClient: CursorUsageClient?
    private var usageInFlight = false
    private var lastUsageAt = Date.distantPast

    init() {
        config = GoldieConfig.load()
        collector = SnapshotCollector(config: config)
        judge = Judge(config: config)
        let blocked = ModelPolicy.blockedKeyword(for: config.llm.model, keywords: config.blockedModelKeywords)
        llm = config.llm.enabled && blocked == nil ? LLMBrain(config: config.llm) : nil
        if blocked != nil {
            brainStatus = "rules (brain model not allowed by policy: \(config.llm.model))"
        } else {
            brainStatus = llm == nil ? "rules (LLM off)" : "rules (waiting for LLM)"
        }
        usageClient = config.cursorUsageAPI ? CursorUsageClient() : nil
        usageStatus = usageClient == nil ? "off in config" : "connecting…"
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    // MARK: Derived UI state

    var bowl: BowlState {
        var s = BowlState()
        s.mood = verdict.mood
        let worst = snapshot.threads.map(\.contextRatio).max() ?? 0
        s.murk = clamp01((worst - 1) / max(config.alarmedRatio - 1, 1))
        let focus = snapshot.thread(focusThread)?.contextRatio ?? worst
        s.puff = 1 + 0.35 * clamp01((focus - 1) / max(config.alarmedRatio - 1, 1))
        s.fryCount = min(5, max(0, snapshot.parallelCount - 1))
        if let month = snapshot.monthUSD, config.monthlyBudgetUSD > 0 {
            s.waterLevel = max(0.15, 1 - month / config.monthlyBudgetUSD)  // never fully empty: she needs water
        }
        return s
    }

    /// The thread the "fresh water" bowl offers a handoff for.
    /// What the fresh bowl and Start fresh act on: your selection, else Goldie's pick.
    var focusThread: String? {
        if let s = selectedThread, snapshot.thread(s) != nil { return s }
        return nudgeTarget
    }

    func select(_ id: String) {
        selectedThread = selectedThread == id ? nil : id
    }

    var nudgeTarget: String? {
        guard verdict.mood == .heavy || verdict.mood == .alarmed, let t = verdict.targetThread,
              !judge.isSnoozed(t, now: Date()) else { return nil }
        return t
    }

    /// Menu bar text: today's spend once known.
    var menuTitle: String {
        guard let today = snapshot.todayUSD else { return "🐠" }
        let count = suggestions.count
        return "🐠 " + Fmt.usd(today) + (count > 0 ? " • \(count)" : "")
    }

    /// Show the setup checklist until the basics work.
    var needsSetup: Bool {
        !snapshot.cursorDBFound || !snapshot.hookEventsSeen || usageStatus.hasPrefix("unavailable")
    }

    // MARK: Loop

    private func tick() {
        let collector = self.collector
        queue.async {
            let snap = collector.collect()
            Task { @MainActor [weak self] in self?.apply(snap) }
        }
        refreshUsageIfDue()
    }

    /// Pulls new Cursor usage events (real $) every few minutes; incremental after the first fetch.
    private func refreshUsageIfDue() {
        let now = Date()
        guard let client = usageClient, !usageInFlight,
              now.timeIntervalSince(lastUsageAt) >= config.usageRefreshMinutes * 60 else { return }
        usageInFlight = true
        lastUsageAt = now
        let from = ledger.fetchStart(now: now)
        Task { @MainActor [weak self] in
            do {
                let (events, complete) = try await client.fetchAll(since: from, until: Date())
                guard let self else { return }
                self.ledger.merge(events, now: Date())
                self.usageStatus = complete ? "connected" : "connected (month total incomplete: too many events)"
                if self.rawSnapshot.takenAt != .distantPast { self.apply(self.rawSnapshot) }
            } catch {
                self?.usageStatus = "unavailable: \(error)"
            }
            self?.usageInFlight = false
        }
    }

    private func apply(_ raw: Snapshot) {
        let now = Date()
        rawSnapshot = raw
        let snap = CostModel.enrich(raw, ledger: ledger, config: config, now: now)
        snapshot = snap
        learn(from: snap, now: now)
        judge.observe(snap, now: now)
        let heuristic = judge.heuristic(snap, now: now)
        let fingerprint = Judge.fingerprint(snap)

        var proposed = heuristic
        if let cached = llmVerdict, cached.fingerprint == fingerprint,
           now.timeIntervalSince(cached.at) < config.judgeIntervalMinutes * 120 {
            proposed = cached.verdict
        }
        let decided = judge.finalize(proposed, heuristic: heuristic, snapshot: snap, now: now)
        verdict = decided
        maybeReappear(decided, now: now)

        if decided.speak, let text = decided.message {
            speech = Speech(text: text, thread: decided.targetThread, until: now.addingTimeInterval(90))
        } else if let s = speech, s.until < now || snap.threads.isEmpty {
            speech = nil
        }

        let stale = now.timeIntervalSince(lastLLMAt) > config.judgeIntervalMinutes * 60
        if llm != nil, !llmInFlight, !snap.threads.isEmpty, fingerprint != lastFingerprint || stale {
            askLLM(snap, heuristic: heuristic, fingerprint: fingerprint, now: now)
        }
        lastFingerprint = fingerprint
    }

    private func askLLM(_ snap: Snapshot, heuristic: Verdict, fingerprint: String, now: Date) {
        guard let llm else { return }
        llmInFlight = true
        lastLLMAt = now
        var context = judge.context(for: snap, heuristic: heuristic, now: now)
        context.modelStats = modelStats
        let ctx = context
        Task { @MainActor [weak self] in
            let result = await llm.judge(ctx)
            guard let self else { return }
            self.llmInFlight = false
            if let result {
                self.llmHealthy = true
                self.brainStatus = "local LLM"
                self.llmVerdict = (verdict: result, fingerprint: fingerprint, at: Date())
                self.apply(self.rawSnapshot)
            } else {
                self.llmHealthy = false
                self.brainStatus = "rules (LLM unreachable)"
            }
        }
    }

    // MARK: Learning

    private func learn(from snap: Snapshot, now: Date) {
        taskStore.record(snap.threads.flatMap(\.tasks), now: now)
        let stats = ModelFit.stats(taskStore.all, since: now.addingTimeInterval(-30 * 24 * 3600))
        if stats != modelStats { modelStats = stats }
        for t in snap.threads { if let s = t.startTokens { startTokensSeen[t.id] = s } }
        let tip = computeSetupTip(now: now)
        if tip != setupTip { setupTip = tip }
        // Tell the user when a guard just saved a wasted step.
        for t in snap.threads {
            if let seen = guardBlocksSeen[t.id], t.guardBlocks > seen {
                showToast("🛡 Goldie stopped a wasted step in “\(t.title)”.", seconds: 5)
            }
            guardBlocksSeen[t.id] = t.guardBlocks
        }
    }

    /// If chats typically start heavy, the fix is in setup (rules, AGENTS.md, MCP tools), not in any one chat.
    private func computeSetupTip(now: Date) -> String? {
        let starts = startTokensSeen.values.sorted()
        guard starts.count >= 3 else { return nil }
        let median = starts[starts.count / 2]
        guard median >= 20_000 else { return nil }
        var tip = "Your chats start at ~\(median / 1000)k tokens before you type anything: rules files, AGENTS.md and MCP tools, re-sent on every step."
        if let rate = ledger.centsPerToken(now: now)["*"] {
            let stepsToday = ledger.events.filter { $0.at >= Calendar.current.startOfDay(for: now) }.count
            let saving = 10_000 * rate * Double(stepsToday) / 100
            if saving >= 0.01 { tip += String(format: " Trimming 10k tokens would have saved ~$%.2f today.", saving) }
        }
        return tip
    }

    func shutdown() {
        taskStore.save(now: Date())
    }

    // MARK: Suggestions

    /// Everything Goldie would fix right now, most valuable first. Shown behind the badge on her bowl.
    var suggestions: [Suggestion] {
        var out: [Suggestion] = []
        let now = Date()
        // Only chats with a clear action *right now*: stuck ones (redirect) and heavy ones waiting at a
        // task boundary (fresh). Mid-task and idle heavy chats are shown in their rows, not nagged about.
        let live = snapshot.threads.filter { !judge.isSnoozed($0.id, now: now) }
        for t in live where t.advice(config: config, now: now) == .redirect {
            var why = "\(t.toolCallsSinceUser) steps since your last message"
            if t.maxRepeatCommand >= 3, let cmd = t.topRepeatedCommand { why = "ran `\(cmd.prefix(40))` \(t.maxRepeatCommand)× with no change" }
            else if t.maxRepeatFileEdit >= 4, let file = t.topRepeatedFile { why = "edited \((file as NSString).lastPathComponent) \(t.maxRepeatFileEdit)×" }
            out.append(Suggestion(id: "redirect-\(t.id)", icon: "arrow.uturn.left.circle", title: "Redirect: “\(t.title)”",
                                  detail: "It \(why). Another lap won't help. Paste a redirect so it summarizes what it learned and proposes a different approach before running anything.",
                                  action: .redirect(t.id)))
        }
        let boundary = live.filter { $0.advice(config: config, now: now) == .freshNow }
            .sorted { ($0.nextTurnCostUSD ?? 0) > ($1.nextTurnCostUSD ?? 0) }
        for t in boundary.prefix(3) {
            var detail = "It's waiting for you and re-reads \(Fmt.tokens(t.contextTokens)) tokens every step"
            if let step = t.nextTurnCostUSD { detail += " (~\(Fmt.usd(step))/step)" }
            if t.contextRatio >= 2 { detail += ". Start your next task in a fresh chat: ~\(Int(t.contextRatio.rounded()))× cheaper per step" }
            out.append(Suggestion(id: "fresh-\(t.id)", icon: "sparkles", title: "Good moment: “\(t.title)”",
                                  detail: detail + ".", action: .startFresh(t.id)))
        }
        if !config.guards.loopGuard, let t = snapshot.threads.first(where: { $0.maxRepeatCommand >= 3 }) {
            out.append(Suggestion(id: "loop-guard", icon: "arrow.triangle.2.circlepath", title: "Turn on Loop guard",
                                  detail: "“\(t.title)” re-ran the same command \(t.maxRepeatCommand)×. Loop guard stops the next identical run when no code changed in between, and tells the agent to change approach.",
                                  action: .enableLoopGuard))
        }
        if !config.guards.readGuard, let t = snapshot.threads.first(where: { $0.bloatTokens >= 10_000 }) {
            out.append(Suggestion(id: "read-guard", icon: "doc.text.magnifyingglass", title: "Turn on Big-read guard",
                                  detail: "“\(t.title)” pulled ~\(Fmt.tokens(t.bloatTokens)) tokens from one read, which is now re-sent every step. Big-read guard makes the agent search large files first (it can still ask again).",
                                  action: .enableReadGuard))
        }
        if let tip = setupTip, let workspace = snapshot.threads.compactMap(\.workspace).first {
            out.append(Suggestion(id: "setup", icon: "gearshape", title: "Trim what every chat starts with",
                                  detail: tip, action: .openRules(workspace)))
        }
        return out.filter { !dismissedSuggestions.contains($0.id) }
    }

    func perform(_ suggestion: Suggestion) {
        switch suggestion.action {
        case .startFresh(let id): startFresh(threadID: id)
        case .redirect(let id): copyRedirect(threadID: id)
        case .enableLoopGuard: setGuard(loop: true)
        case .enableReadGuard: setGuard(read: true)
        case .openRules(let workspace): openRules(in: workspace)
        }
    }

    func dismiss(_ suggestion: Suggestion) {
        dismissedSuggestions.insert(suggestion.id)
        if case .startFresh(let id) = suggestion.action { judge.snooze(thread: id, now: Date()) }
    }

    /// Turns on suggested guards, then starts fresh chats one at a time (at most 3).
    func fixAll() {
        let items = suggestions
        expanded = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            for s in items {
                switch s.action {
                case .enableLoopGuard: self.setGuard(loop: true)
                case .enableReadGuard: self.setGuard(read: true)
                default: break
                }
            }
            for s in items {
                if case .startFresh(let id) = s.action {
                    await self.startFreshNow(threadID: id)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    // MARK: Actions

    func startFresh(threadID: String) {
        Task { @MainActor [weak self] in await self?.startFreshNow(threadID: threadID) }
    }

    /// Handoff → saved in the chat's repo → new Cursor chat opened (and sent) by the autopilot.
    private func startFreshNow(threadID: String) async {
        let chat = snapshot.thread(threadID)
        showToast("Writing a handoff for “\(chat?.title ?? "this chat")”…", seconds: 30)
        let collector = self.collector
        let queue = self.queue
        let source: HandoffSource? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: collector.handoffSource(threadID: threadID)) }
        }
        guard let source else {
            showToast("Couldn't read that chat.")
            return
        }
        var text = Handoff.draft(source)
        if let llm, llmHealthy, let refined = await llm.refineHandoff(text) { text = refined }

        var prompt = text
        if let saved = HandoffWriter.write(text, title: chat?.title ?? source.title, workspace: chat?.workspace, now: Date()) {
            prompt = HandoffWriter.prompt(relativePath: saved.relativePath)
        }
        judge.recordFeedback(thread: threadID, feedback: "started fresh")
        dismissedSuggestions.insert("fresh-\(threadID)")
        speech = nil
        expanded = false
        let status = await CursorAutopilot.startNewChat(prompt: prompt, workspace: chat?.workspace, config: config.autopilot)
        showToast(status, seconds: 7)
    }

    /// For a stuck chat, a better first move than a new chat: make the agent stop and rethink.
    func copyRedirect(threadID: String) {
        guard let t = snapshot.thread(threadID) else { return }
        var what = "you've taken \(t.toolCallsSinceUser) steps since my last message"
        if t.maxRepeatCommand >= 3, let cmd = t.topRepeatedCommand {
            what = "you've run `\(cmd)` \(t.maxRepeatCommand) times and the result isn't changing"
        } else if t.maxRepeatFileEdit >= 4, let file = t.topRepeatedFile {
            what = "you've edited \((file as NSString).lastPathComponent) \(t.maxRepeatFileEdit) times"
        }
        let prompt = "Pause: \(what). Don't run or edit anything yet. In 5 bullets: what you've tried, what you learned, and your best hypothesis now. Then propose one different next step and wait for my OK."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        CursorAutopilot.bringCursorForward(workspace: t.workspace)
        judge.recordFeedback(thread: threadID, feedback: "copied redirect")
        dismissedSuggestions.insert("redirect-\(threadID)")
        expanded = false
        showToast("Redirect copied. Paste it into “\(t.title)” (⌘V).", seconds: 6)
    }

    // MARK: Hiding

    enum HideMode { case untilShown, forAnHour, untilNeeded }

    /// Set by the panel controller: actually shows/hides the floating window.
    var setPanelVisible: ((Bool) -> Void)?
    private var hiddenUntil: Date?
    private var hiddenUntilNeeded = false
    /// What was already going on when you hid her; only something *new* brings her back.
    private var alarmedWhenHidden = false
    private var targetWhenHidden: String?

    func hide(_ mode: HideMode) {
        expanded = false
        hiddenUntil = mode == .forAnHour ? Date().addingTimeInterval(3600) : nil
        hiddenUntilNeeded = mode == .untilNeeded
        alarmedWhenHidden = verdict.mood == .alarmed
        targetWhenHidden = verdict.targetThread
        setPanelVisible?(false)
        let hint: String
        switch mode {
        case .untilShown: hint = "Goldie is hidden. Bring her back from the 🐠 in the menu bar."
        case .forAnHour: hint = "Goldie is hidden for an hour."
        case .untilNeeded: hint = "Goldie is hidden until something needs you."
        }
        hiddenHint = hint
    }

    func showGoldie() {
        hiddenUntil = nil
        hiddenUntilNeeded = false
        hiddenHint = nil
        setPanelVisible?(true)
    }

    /// Called every poll: bring her back when the hour is up or something needs you.
    private func maybeReappear(_ verdict: Verdict, now: Date) {
        guard !panelVisible else { return }
        if let until = hiddenUntil, now >= until {
            showGoldie()
        } else if hiddenUntilNeeded {
            let newNudge = verdict.speak && verdict.targetThread != targetWhenHidden
            let newAlarm = verdict.mood == .alarmed && !alarmedWhenHidden
            if newNudge || newAlarm { showGoldie() }
            // Once the earlier alarm clears, a later one counts as new.
            if verdict.mood != .alarmed { alarmedWhenHidden = false }
        }
    }

    /// Hidden Goldie can't show a toast, so the menu shows why she's gone.
    @Published private(set) var hiddenHint: String?

    func snooze(threadID: String) {
        judge.snooze(thread: threadID, now: Date())
        if speech?.thread == threadID { speech = nil }
        showToast("Goldie won't nudge about this chat for \(Int(config.snoozeMinutes)) min")
        apply(rawSnapshot)
    }

    func notHelpful() {
        let key = verdict.targetThread ?? "_global"
        judge.notHelpful(thread: key, now: Date())
        speech = nil
        showToast("Noted. I'll back off.")
        apply(rawSnapshot)
    }

    /// Guards are enforced by Cursor's before-* hooks, so turning one on (re)installs hooks.
    func setGuard(loop: Bool? = nil, read: Bool? = nil) {
        updateConfig { c in
            if let loop { c.guards.loopGuard = loop }
            if let read { c.guards.readGuard = read }
        }
        let names = [config.guards.loopGuard ? "Loop guard" : nil, config.guards.readGuard ? "Big-read guard" : nil].compactMap { $0 }
        if installHooks(quiet: true) {
            showToast(names.isEmpty ? "Guards off." : "\(names.joined(separator: " + ")) on. If it doesn't kick in, restart Cursor.", seconds: 6)
        }
    }

    func setAutoSend(_ on: Bool) {
        updateConfig { $0.autopilot.autoSend = on }
        showToast(on ? "Start fresh will send the new chat for you." : "Start fresh will stop before sending, so you press Enter.")
    }

    /// Re-read the file, change one thing, save: never clobbers edits made via "Open config".
    private func updateConfig(_ change: (inout GoldieConfig) -> Void) {
        var onDisk = GoldieConfig.load()
        change(&onDisk)
        onDisk.save()
        change(&config)
    }

    @discardableResult
    func installHooks(quiet: Bool = false) -> Bool {
        let cli = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("goldiectl")
        guard let cli, FileManager.default.isExecutableFile(atPath: cli.path) else {
            showToast("Build goldiectl first: swift build -c release")
            return false
        }
        do {
            let message = try CursorHooksInstaller.install(executable: cli.path,
                                                           guards: config.guards.loopGuard || config.guards.readGuard)
            if !quiet { showToast(message, seconds: 6) }
            return true
        } catch {
            showToast("Hook install failed: \(error)", seconds: 6)
            return false
        }
    }

    func openConfig() {
        NSWorkspace.shared.open(GoldieConfig.writeDefaultIfMissing())
    }

    /// Opens the files that load into every chat (rules, AGENTS.md) so you can trim them.
    private func openRules(in workspace: String) {
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
        let candidates = [".cursor/rules", "AGENTS.md", ".cursorrules", "CLAUDE.md", ".cursor/mcp.json"]
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if candidates.isEmpty {
            NSWorkspace.shared.open(root)
        } else {
            candidates.forEach { NSWorkspace.shared.open($0) }
        }
    }

    func dismissSpeech() { speech = nil }

    private func showToast(_ text: String, seconds: Double = 3) {
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.toast == text { self?.toast = nil }
        }
    }
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

struct Suggestion: Identifiable, Equatable {
    enum Action: Equatable {
        case startFresh(String)
        case redirect(String)
        case enableLoopGuard
        case enableReadGuard
        case openRules(String)
    }

    let id: String
    let icon: String
    let title: String
    let detail: String
    let action: Action

    var actionLabel: String {
        switch action {
        case .startFresh: return "Start fresh"
        case .redirect: return "Copy redirect"
        case .enableLoopGuard, .enableReadGuard: return "Turn on"
        case .openRules: return "Open files"
        }
    }
}
