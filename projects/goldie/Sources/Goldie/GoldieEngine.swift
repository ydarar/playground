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

    let config: GoldieConfig
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
        return "🐠 " + Fmt.usd(today) + (nudgeTarget != nil ? " •" : "")
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
        let ctx = judge.context(for: snap, heuristic: heuristic, now: now)
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

    // MARK: Actions

    func copyHandoff(threadID: String) {
        showToast("writing handoff…", seconds: 30)
        let collector = self.collector
        queue.async {
            let source = collector.handoffSource(threadID: threadID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let source else {
                    self.showToast("couldn't read that thread")
                    return
                }
                var text = Handoff.draft(source)
                if let llm = self.llm, self.llmHealthy, let refined = await llm.refineHandoff(text) {
                    text = refined
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.judge.recordFeedback(thread: threadID, feedback: "copied handoff")
                self.speech = nil
                self.expanded = false
                self.showToast("Handoff copied. In Cursor: start a new chat and paste (⌘V).", seconds: 6)
                Self.bringCursorForward()
            }
        }
    }

    func snooze(threadID: String) {
        judge.snooze(thread: threadID, now: Date())
        if speech?.thread == threadID { speech = nil }
        showToast("snoozed for \(Int(config.snoozeMinutes)) min")
        apply(rawSnapshot)
    }

    func notHelpful() {
        let key = verdict.targetThread ?? "_global"
        judge.notHelpful(thread: key, now: Date())
        speech = nil
        showToast("noted. i'll back off")
        apply(rawSnapshot)
    }

    func installHooks() {
        let cli = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("goldiectl")
        guard let cli, FileManager.default.isExecutableFile(atPath: cli.path) else {
            showToast("build goldiectl first: swift build -c release")
            return
        }
        do {
            showToast(try CursorHooksInstaller.install(executable: cli.path), seconds: 6)
        } catch {
            showToast("hook install failed: \(error)", seconds: 6)
        }
    }

    func openConfig() {
        NSWorkspace.shared.open(GoldieConfig.writeDefaultIfMissing())
    }

    /// After "Start fresh", put Cursor in front so the paste is one keystroke away.
    private static func bringCursorForward() {
        // A background (accessory) app can't pull another app forward with activate() on macOS 14+;
        // asking the system to open the app works.
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == "Cursor" }
        guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
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
