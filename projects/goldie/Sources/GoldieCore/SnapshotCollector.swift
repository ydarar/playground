import Foundation

/// Merges the two Cursor sensors (hooks log + state DB) into a `Snapshot`.
/// Not thread-safe: call from one serial queue.
public final class SnapshotCollector {
    public let config: GoldieConfig
    private let store: CursorStore
    private let hooks: HookTracker
    private var cache: [String: (signature: String, thread: CursorThread)] = [:]
    private let baseline = BaselineLearner()

    public init(config: GoldieConfig, store: CursorStore = CursorStore(), hooks: HookTracker = HookTracker()) {
        self.config = config
        self.store = store
        self.hooks = hooks
    }

    public func collect(now: Date = Date()) -> Snapshot {
        hooks.poll(now: now)
        let window = self.config.activeWindowMinutes * 60
        // "N× cheaper than a fresh chat" uses what fresh chats really cost you, not a guess.
        var config = self.config
        config.freshBaselineTokens = baseline.baseline(fallback: self.config.freshBaselineTokens)
        let subagents = store.subagentIDs(now: now)

        // Candidates: recently written composers, plus anything hooks saw recently.
        var candidates: [String: String] = [:]  // id → DB signature ("" = look it up)
        for ref in store.recentComposers(limit: 40, now: now) {
            if let updated = ref.updated, now.timeIntervalSince(updated) > window { continue }
            candidates[ref.id] = ref.signature
        }
        for (id, state) in hooks.threads where now.timeIntervalSince(state.lastEventAt) <= window && !subagents.contains(id) {
            if candidates[id] == nil { candidates[id] = "" }
        }

        var threads: [ThreadSnapshot] = []
        for (id, dbSignature) in candidates {
            let hook = hooks.threads[id]
            let signature = dbSignature.isEmpty ? store.signature(id: id) : dbSignature
            let hookPart = hook.map { String($0.lastEventAt.timeIntervalSince1970) } ?? "-"
            let thread = loadThread(id: id, signature: signature.map { $0 + "|" + hookPart })
            if thread == nil && hook == nil { continue }
            if let thread, thread.bubbles.isEmpty, hook == nil { continue }  // empty new chat
            let snap = Signals.build(id: id, thread: thread, hook: hook, config: config, now: now)
            if now.timeIntervalSince(snap.lastActivity) <= window { threads.append(snap) }
        }
        threads.sort { $0.lastActivity > $1.lastActivity }
        threads.forEach(baseline.observe)
        baseline.saveIfNeeded()

        let parallelWindow = config.parallelWindowMinutes * 60
        let parallel = threads.filter { $0.running || now.timeIntervalSince($0.lastActivity) <= parallelWindow }.count
        cache = cache.filter { entry in threads.contains { $0.id == entry.key } }
        store.retainCache(for: Set(candidates.keys))

        var snapshot = Snapshot(threads: threads, parallelCount: parallel, takenAt: now,
                                cursorDBFound: store.exists, hookEventsSeen: hooks.hasSeenEvents)
        snapshot.freshBaselineTokens = config.freshBaselineTokens
        return snapshot
    }

    public func handoffSource(threadID: String) -> HandoffSource? {
        store.loadThread(id: threadID).map(HandoffSource.init(thread:))
    }

    private func loadThread(id: String, signature: String?) -> CursorThread? {
        if let signature, let cached = cache[id], cached.signature == signature { return cached.thread }
        guard let thread = store.loadThread(id: id) else { return nil }
        if let signature { cache[id] = (signature, thread) }
        return thread
    }
}
