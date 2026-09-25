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
    /// Monthly budget left. POC: always full (spend meters come later).
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
    @Published var expanded = false

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

    init() {
        config = GoldieConfig.load()
        collector = SnapshotCollector(config: config)
        judge = Judge(config: config)
        llm = config.llm.enabled ? LLMBrain(config: config.llm) : nil
        brainStatus = llm == nil ? "rules (LLM off)" : "rules (waiting for LLM)"
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Derived UI state

    var bowl: BowlState {
        var s = BowlState()
        s.mood = verdict.mood
        let worst = snapshot.threads.map(\.contextRatio).max() ?? 0
        s.murk = clamp01((worst - 1) / max(config.alarmedRatio - 1, 1))
        let focus = snapshot.thread(verdict.targetThread)?.contextRatio ?? worst
        s.puff = 1 + 0.35 * clamp01((focus - 1) / max(config.alarmedRatio - 1, 1))
        s.fryCount = min(5, max(0, snapshot.parallelCount - 1))
        return s
    }

    /// The thread the "fresh water" bowl offers a handoff for.
    var nudgeTarget: String? {
        guard verdict.mood == .heavy || verdict.mood == .alarmed, let t = verdict.targetThread,
              !judge.isSnoozed(t, now: Date()) else { return nil }
        return t
    }

    var emptyHint: String? {
        if !snapshot.cursorDBFound { return "Cursor's state DB wasn't found. Is Cursor installed?" }
        if !snapshot.hookEventsSeen { return "No hook events yet. Menu bar → Install Cursor hooks, then restart Cursor." }
        if snapshot.threads.isEmpty { return "No Cursor agent activity in the last \(Int(config.activeWindowMinutes)) min." }
        return nil
    }

    // MARK: Loop

    private func tick() {
        let collector = self.collector
        queue.async {
            let snap = collector.collect()
            Task { @MainActor [weak self] in self?.apply(snap) }
        }
    }

    private func apply(_ snap: Snapshot) {
        let now = Date()
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
                self.apply(self.snapshot)
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
                self.showToast("handoff copied. paste it into a new chat 🐠")
            }
        }
    }

    func snooze(threadID: String) {
        judge.snooze(thread: threadID, now: Date())
        if speech?.thread == threadID { speech = nil }
        showToast("snoozed for \(Int(config.snoozeMinutes)) min")
        apply(snapshot)
    }

    func notHelpful() {
        let key = verdict.targetThread ?? "_global"
        judge.notHelpful(thread: key, now: Date())
        speech = nil
        showToast("noted. i'll back off")
        apply(snapshot)
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

    private func showToast(_ text: String, seconds: Double = 3) {
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.toast == text { self?.toast = nil }
        }
    }
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
