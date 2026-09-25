import GoldieCore
import SwiftUI

// MARK: - Root

struct GoldieRootView: View {
    @ObservedObject var engine: GoldieEngine
    let mover: WindowMover
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer(minLength: 0)
            if engine.expanded {
                DetailsCard(engine: engine)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let toast = engine.toast {
                ToastView(text: toast)
            }
            if let speech = engine.speech, !engine.expanded {
                SpeechBubble(text: speech.text, chat: engine.snapshot.thread(speech.thread)?.title)
                    .onTapGesture {
                        engine.dismissSpeech()
                        withAnimation(.spring(response: 0.3)) { engine.expanded = true }
                    }
            } else if hovering, !engine.expanded, engine.toast == nil {
                PeekView(engine: engine)
            }
            HStack(alignment: .bottom, spacing: 10) {
                BowlView(state: engine.bowl, paused: !engine.panelVisible, size: CGFloat(engine.bowlSize), hovering: hovering)
                    .overlay(alignment: .topTrailing) {
                        let count = engine.suggestions.count
                        if count > 0 {
                            SuggestionBadge(count: count)
                                .offset(x: -6, y: 6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { _ in mover.drag() }
                            .onEnded { _ in mover.end() }
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) { engine.expanded.toggle() }
                    }
                    .onHover { hovering = $0 }
                    .contextMenu { Button("Hide Goldie") { engine.hide() } }
                    .help(engine.suggestions.isEmpty ? "Click for details · drag to move" : "Goldie has suggestions: click to see them")
            }
        }
        .padding(10)
        .frame(width: PanelController.size.width, height: PanelController.size.height, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.25), value: engine.suggestions.count)
        .animation(.easeInOut(duration: 0.25), value: engine.speech)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Small overlays

/// Hover peek: the one-glance answer without opening anything.
struct PeekView: View {
    @ObservedObject var engine: GoldieEngine

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(engine.verdict.mood.color).frame(width: 7, height: 7)
            Text(engine.verdict.mood.label).fontWeight(.semibold)
            if engine.snapshot.todayUSD != nil {
                Text("· today \(Fmt.usd(engine.snapshot.todayUSD))")
            }
            Text("· click for details").foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .rounded))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.8)))
            .foregroundStyle(.white)
            .frame(maxWidth: 330, alignment: .trailing)
    }
}

/// White bubble with a tail pointing down at Goldie. Tap = open details.
struct SpeechBubble: View {
    let text: String
    /// Which chat she means.
    var chat: String? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if let chat {
                    Text(chat).font(.system(size: 11, design: .rounded)).opacity(0.6).lineLimit(1)
                }
            }
            .frame(maxWidth: 240, alignment: .leading)
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            BubbleTail()
                .fill(Color.white)
                .frame(width: 16, height: 9)
                .padding(.trailing, 60)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(.trailing, 20)
        .help("Click for details")
    }
}

struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.2, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Details card

enum Severity {
    /// 0 fine, 1 getting heavy, 2 needs attention.
    static func of(_ t: ThreadSnapshot, config: GoldieConfig) -> Int {
        if t.loopScore >= 0.75 || t.contextRatio >= config.alarmedRatio { return 2 }
        if t.loopScore >= 0.5 || t.contextRatio >= config.heavyRatio || t.isOverCap(config) { return 1 }
        return 0
    }

    static func color(_ level: Int) -> Color {
        switch level {
        case 2: return .red
        case 1: return .orange
        default: return .green
        }
    }
}

struct DetailsCard: View {
    @ObservedObject var engine: GoldieEngine
    @State private var showLegend = false

    /// Room above the bowl; the card scrolls when its content is taller.
    private var maxBodyHeight: CGFloat {
        max(220, PanelController.size.height - CGFloat(engine.bowlSize) - 150)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header  // pinned: close/hide are always reachable
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical, showsIndicators: true) { content.padding(.trailing, 6) }
            }
            .frame(maxHeight: maxBodyHeight)
        }
        .padding(14)
        .frame(width: 350, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showLegend { Legend() }
            if engine.needsSetup { SetupChecklist(engine: engine) }
            BudgetSection(snapshot: engine.snapshot, sources: engine.sources, budget: engine.config.monthlyBudgetUSD)
            if !engine.suggestions.isEmpty { SuggestionsSection(engine: engine) }
            threadList
            if !engine.snapshot.overCapChats.isEmpty { OverCapSection(engine: engine) }
            TipsSection(engine: engine)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Goldie").font(.system(.headline, design: .rounded))
            Text(engine.verdict.mood.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(engine.verdict.mood.color.opacity(0.22)))
            Spacer()
            Text(engine.brainStatus == "local LLM" ? "local AI" : "rules")
                .font(.caption2).foregroundStyle(.secondary)
                .help("Who's judging: \(engine.brainStatus)")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLegend.toggle() }
            } label: {
                Image(systemName: showLegend ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showLegend ? Color.accentColor : Color.secondary)
            .help(showLegend ? "Hide explanations" : "What do these mean?")
            Button { engine.hide() } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide Goldie (bring her back from the menu bar or with ⌃⌥⌘G)")
            Button {
                withAnimation(.spring(response: 0.3)) { engine.expanded = false }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
    }

    private var sortedThreads: [ThreadSnapshot] {
        let target = engine.verdict.targetThread
        let config = engine.config
        return engine.snapshot.threads.sorted { a, b in
            if (a.id == target) != (b.id == target) { return a.id == target }
            let sa = Severity.of(a, config: config)
            let sb = Severity.of(b, config: config)
            if sa != sb { return sa > sb }
            if a.running != b.running { return a.running }
            return a.lastActivity > b.lastActivity
        }
    }

    @ViewBuilder private var threadList: some View {
        if engine.snapshot.threads.isEmpty {
            if !engine.needsSetup {
                Text("No Cursor agent chats in the last \(Int(engine.config.activeWindowMinutes)) min. Goldie's napping. 😴")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(sortedThreads) { thread in
                    ThreadRow(thread: thread,
                              isTarget: thread.id == engine.nudgeTarget,
                              isSelected: thread.id == engine.selectedThread,
                              engine: engine)
                }
            }
        }
    }

    private var footer: some View {
        Text("\(engine.snapshot.threads.count) chat(s) · updates every \(Int(engine.config.pollSeconds))s")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// One budget across every AI tool, with who's contributing, and a tick for where even spending
/// would put you today.
struct BudgetSection: View {
    let snapshot: Snapshot
    let sources: [SourceSpend]
    let budget: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Token Budget").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(headline)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(overPace ? Color.red : Color.primary)
            }
            BudgetBar(segments: segments, pace: paceFraction)
                .frame(height: 8)
            HStack(spacing: 12) {
                ForEach(sources) { source in SourceChip(source: source) }
            }
            Text(subline).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        guard let total = snapshot.totalMonthUSD else { return "—" }
        return "\(Fmt.usd(total)) of \(Fmt.usd(budget))"
    }

    private var segments: [BudgetSegment] {
        guard budget > 0 else { return [] }
        return sources.compactMap { s in
            s.monthUSD.map { BudgetSegment(color: SourceStyle.color(s.id), fraction: $0 / budget) }
        }
    }

    private var paceFraction: Double {
        let now = Date()
        guard let month = Calendar.current.dateInterval(of: .month, for: now) else { return 0 }
        return now.timeIntervalSince(month.start) / month.duration
    }

    private var overPace: Bool { (snapshot.projectedMonthUSD ?? 0) > budget }

    private var subline: String {
        guard snapshot.totalMonthUSD != nil else { return "No costs connected yet. Hover the icons to see why." }
        var parts: [String] = []
        if let projected = snapshot.projectedMonthUSD { parts.append("On pace for ~\(Fmt.usd(projected)) this month") }
        if let today = snapshot.todayUSD { parts.append("Cursor today \(Fmt.usd(today))") }
        return parts.joined(separator: " · ")
    }
}

struct BudgetSegment {
    let color: Color
    let fraction: Double
}

/// Stacked by tool, so you can see who's eating the budget.
struct BudgetBar: View {
    let segments: [BudgetSegment]
    let pace: Double

    var body: some View {
        GeometryReader { geo in
            let total = segments.reduce(0) { $0 + $1.fraction }
            let scale = total > 1 ? 1 / total : 1  // over budget: fill the bar, keep the proportions
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, geo.size.width * CGFloat(segment.fraction * scale)))
                    }
                }
                .clipShape(Capsule())
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: geo.size.width * CGFloat(clamp01(pace)) - 1)
            }
        }
        .help("Colored by tool. Tick: where you'd be today if you spent evenly all month.")
    }
}

struct SourceChip: View {
    let source: SourceSpend

    var body: some View {
        HStack(spacing: 4) {
            SourceIcon(id: source.id)
            Text(source.monthUSD.map { Fmt.usd($0) } ?? "—")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(source.monthUSD == nil ? Color.secondary : Color.primary)
        }
        .help("\(source.id.name): \(source.status)")
    }
}

/// Small badge per tool. Stand-in symbols (not the tools' official logos).
struct SourceIcon: View {
    let id: SpendSourceID
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: SourceStyle.symbol(id))
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(SourceStyle.color(id)))
    }
}

enum SourceStyle {
    static func symbol(_ id: SpendSourceID) -> String {
        switch id {
        case .cursor: return "cursorarrow"
        case .claude: return "sparkle"
        case .codex: return "terminal"
        case .opencode: return "curlybraces"
        }
    }

    static func color(_ id: SpendSourceID) -> Color {
        switch id {
        case .cursor: return Color(red: 0.30, green: 0.36, blue: 0.46)
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.13, green: 0.60, blue: 0.50)
        case .opencode: return Color(red: 0.47, green: 0.36, blue: 0.86)
        }
    }
}

struct SetupChecklist: View {
    @ObservedObject var engine: GoldieEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            check("Cursor found", ok: engine.snapshot.cursorDBFound, hint: "Install Cursor and open it once.")
            HStack(alignment: .top) {
                check("Cursor hooks", ok: engine.snapshot.hookEventsSeen, hint: "Install, then quit and reopen Cursor.")
                if !engine.snapshot.hookEventsSeen {
                    Spacer()
                    Button("Install") { engine.installHooks() }.controlSize(.small)
                }
            }
            check("Cursor costs", ok: engine.usageStatus.hasPrefix("connected"), hint: engine.usageStatus)
            check("Local AI brain (optional)", ok: engine.brainStatus == "local LLM",
                  hint: "Run mlx_lm.server (see README). Rules work in the meantime.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func check(_ title: String, ok: Bool, hint: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                if !ok {
                    Text(hint).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSnapshot
    /// Goldie's own pick for a fresh start.
    let isTarget: Bool
    /// You clicked this row.
    let isSelected: Bool
    @ObservedObject var engine: GoldieEngine

    private var severity: Int { Severity.of(thread, config: engine.config) }
    private var overCap: Bool { thread.isOverCap(engine.config) }
    private var color: Color { Severity.color(severity) }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isTarget && !isSelected {
                        Text("Goldie's pick")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                    }
                    if overCap {
                        CapBadge(cap: engine.config.chatCapUSD)
                            .help("Spent \(Fmt.usd(thread.spentUSD)) this month. Your per-chat cap is \(Fmt.usd(engine.config.chatCapUSD)) (chatCapUSD in config).")
                    }
                    Spacer()
                    Text(thread.running ? "running" : Fmt.idle(thread.lastActivity))
                        .font(.caption2)
                        .foregroundStyle(thread.running ? Color.green : Color.secondary)
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ContextMeter(label: meterLabel, fraction: clamp01(thread.contextRatio / max(engine.config.alarmedRatio, 1)), color: color)
                if let warning = warningLine {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(color == .green ? Color.orange : color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tip = tipLine {
                    Text(tip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = situationLine {
                    Text(line)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(isSelected ? Color.orange.opacity(0.14) : Color.primary.opacity(isTarget ? 0.09 : 0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color.orange : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { engine.select(thread.id) } }
        .help(rowHelp)
    }

    private var rowHelp: String {
        isSelected ? "Selected. Click again to deselect." : "Click to select this chat"
    }

    /// "debugging · grok-4.7 · spent $4.10 · last task $1.40 · ~$0.12/step"
    private var metaLine: String {
        var parts: [String] = []
        if let kind = thread.dominantKind { parts.append(kind.rawValue) }
        parts.append(thread.effectiveModel ?? "unknown model")
        if thread.maxMode { parts.append("Max Mode") }
        if let spent = thread.spentUSD { parts.append("spent \(Fmt.usd(spent))") }
        if let last = thread.lastMessageUSD, last > 0 { parts.append("last task \(Fmt.usd(last))") }
        if let step = thread.nextTurnCostUSD {
            parts.append("~\(Fmt.usd(step))/step" + (thread.costSource == "cursor" ? "" : " est."))
        }
        return parts.joined(separator: " · ")
    }

    private var meterLabel: String {
        let approx = thread.contextSource == "estimated" ? "~" : ""
        return "\(approx)\(Fmt.tokens(thread.contextTokens)) re-read/step"
    }

    /// Something is wrong right now.
    private var warningLine: String? {
        let keywords = engine.config.blockedModelKeywords
        if let blocked = [thread.billedModel, thread.model].compactMap({ $0 }).first(where: { ModelPolicy.blockedKeyword(for: $0, keywords: keywords) != nil }) {
            return "⛔︎ Uses \(blocked), a Chinese-vendor model. Switch to an approved model."
        }
        if thread.maxRepeatCommand >= 3, let cmd = thread.topRepeatedCommand {
            return "⚠︎ Ran `\(cmd.prefix(40))` \(thread.maxRepeatCommand)× in a row. Probably stuck."
        }
        if thread.maxRepeatFileEdit >= 4, let file = thread.topRepeatedFile {
            return "⚠︎ Edited \((file as NSString).lastPathComponent) \(thread.maxRepeatFileEdit)×. Probably going in circles."
        }
        if thread.toolCallsSinceUser >= 15 {
            return "⚠︎ \(thread.toolCallsSinceUser) steps since your last message."
        }
        return nil
    }

    /// The single most useful way to make this chat cheaper, strongest evidence first.
    private var advice: ChatAdvice { thread.advice(config: engine.config, now: Date()) }

    /// What to do about this chat right now, in plain words.
    private var situationLine: String? {
        switch advice {
        case .redirect: return "↩︎ Stuck: send a redirect rather than another lap (or start fresh with a don't-repeat list)."
        case .freshNow: return "✨ Good moment: it's waiting for you. Start your next task in a fresh chat."
        case .finishThenFresh: return "⏳ Mid-task: let it finish here, then start the next task fresh."
        case .idleHeavy: return "💤 Idle, so it costs nothing now. If you come back to it, start fresh instead."
        case .fine:
            guard overCap else { return nil }
            return thread.running
                ? "💸 Past your \(Fmt.usd(engine.config.chatCapUSD)) chat cap. Let this task finish, then start the next one fresh."
                : "💸 Past your \(Fmt.usd(engine.config.chatCapUSD)) chat cap. Start your next task in a fresh chat."
        }
    }

    /// The main action matches the situation; Copy handoff is always there as a secondary option.
    @ViewBuilder private var actions: some View {
        let emphasize = isSelected || advice == .freshNow || (overCap && !thread.running)
        HStack(spacing: 12) {
            if advice == .redirect {
                Button("Copy redirect") { engine.copyRedirect(threadID: thread.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
            }
            if emphasize && advice != .redirect {
                Button("Copy handoff") { engine.startFresh(threadID: thread.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
            } else {
                Button("Copy handoff") { engine.startFresh(threadID: thread.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if isTarget {
                Spacer()
                Button("Not helpful") { engine.notHelpful() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Goldie backs off this chat for a while")
            }
        }
    }

    private var tipLine: String? {
        if let kind = thread.currentKind,
           let fit = ModelFit.advice(kind: kind, model: thread.effectiveModel, stats: engine.modelStats) {
            return "💡 " + fit
        }
        if thread.bloatTokens >= 10_000, let label = thread.bloatLabel {
            return "📄 \(label) (~\(Fmt.tokens(thread.bloatTokens)) tokens) is re-sent on every step. Next time ask for just the lines you need, or start fresh."
        }
        if advice != .fine, thread.contextRatio >= 2 {
            return "A fresh chat would be ~\(Int(thread.contextRatio.rounded()))× cheaper per step (fresh ≈ \(Fmt.tokens(engine.snapshot.freshBaselineTokens)) tokens, learned from your chats)."
        }
        return nil
    }
}

/// How heavy the chat is: full bar = time to start fresh.
struct ContextMeter: View {
    let label: String
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(4, geo.size.width * CGFloat(clamp01(fraction))))
                }
            }
            .frame(height: 5)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .help("How much of the chat is re-sent on every step. A full bar means it's time to start fresh.")
    }
}

struct Legend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            item("Step", "One call to the model. A single message can trigger many steps: read a file, run a command, edit, and so on.")
            item("Re-read/step bar", "The agent re-sends the whole chat on every step, so long chats pay for their history again and again. Full bar = time to start fresh.")
            item("A new chat would be ~N× cheaper", "Compared with a fresh chat that starts from a short handoff (~15k tokens).")
            item("Spent · last task · per step", "Real charges from your Cursor usage, matched to each chat by time. Close, not exact. A task is one message plus everything the agent did for it. \"est.\" = estimated from tokens.")
            item("💡 Model advice", "Only from your own history: cost per task that actually worked, by kind of work. A cheaper-per-step model can cost more per task if it loops or needs redoing, so Goldie compares whole tasks and needs 5+ tasks on each side. The full table is in the menu bar → Model scorecard.")
            item("📄 Big reads", "One huge file or log in a chat is re-sent on every later step. Asking for just the lines you need keeps chats light.")
            item("AI Token Budget", "Month spend across Cursor, Claude, Codex and OpenCode vs your budget, colored by tool (hover an icon for its status). The tick shows where even spending would put you today. Goldie's water drains as you spend.")
            item("When to start fresh", "At a task boundary: the chat is heavy and waiting for you (✨). Mid-task (⏳), let it finish, because a new chat would re-pay to rediscover everything. Idle chats (💤) cost nothing. Stuck chats (↩︎) usually need a redirect, not a new chat.")
            item("Copy redirect", "Copies a message telling the agent to stop, summarize what it learned, and propose a different approach before running anything. Paste it into that chat.")
            item("Copy handoff", "Copies a handoff (goal, where things stand, files that matter, what not to redo) to your clipboard. Paste it into a new chat.")
            item("Over the chat cap", "A chat that has cost more than your per-chat cap this month (chatCapUSD, default $20: about half a working day of an $800 month). Marked in the chat list, and listed with closed chats under “Over the cap this month”. Goldie says so once when a chat crosses it.")
            item("Suggestions", "The number on Goldie's bowl: things worth doing now, each with its own button.")
            item("Guards", "Loop guard stops a command repeated with no code change in between. Big-read guard makes the agent search large files first; asking again is allowed. Both are opt-in (menu bar).")
        }
        .font(.caption)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Account-wide tip about what every chat starts with. (The model scorecard lives in the menu bar.)
struct TipsSection: View {
    @ObservedObject var engine: GoldieEngine

    var body: some View {
        if let tip = engine.setupTip {
            Text("⚙︎ " + tip).font(.caption).fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// Menu bar → Model scorecard: what each model costs you per task that worked, by kind of work.
struct ModelScorecardMenu: View {
    let stats: [ModelStats]

    var body: some View {
        ForEach(TaskKind.allCases, id: \.self) { kind in
            let rows = stats.filter { $0.kind == kind }.sorted { $0.costPerGoodTaskUSD < $1.costPerGoodTaskUSD }
            if !rows.isEmpty {
                Section(kind.label) {
                    ForEach(rows, id: \.model) { row in
                        Text(Self.line(row, best: row.model == rows.first?.model && rows.count > 1))
                    }
                }
            }
        }
        Divider()
        Text("Median cost per task, adjusted for tasks that looped or were redone.")
        Text("✓ = cheapest with \(ModelFit.minTasks)+ tasks. Fewer tasks: not enough evidence yet.")
    }

    static func line(_ s: ModelStats, best: Bool) -> String {
        let mark = best && s.count >= ModelFit.minTasks ? "✓ " : ""
        let few = s.count < ModelFit.minTasks ? " (few tasks)" : ""
        return mark + String(format: "%@: $%.2f/task · %ld tasks · %.0f%% redone · ~%ld steps",
                             s.model, s.costPerGoodTaskUSD, s.count, s.troubleRate * 100, s.medianSteps) + few
    }
}

/// Orange count on the bowl: how many things Goldie would fix.
struct SuggestionBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 22, minHeight: 22)
            .background(Circle().fill(Color.orange))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

struct SuggestionsSection: View {
    @ObservedObject var engine: GoldieEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goldie's suggestions").font(.caption.weight(.semibold))
            ForEach(engine.suggestions) { suggestion in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: suggestion.icon)
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(suggestion.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button(suggestion.actionLabel) { engine.perform(suggestion) }
                            Button("Dismiss") { engine.dismiss(suggestion) }
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
    }
}

/// Red "over $20" tag on a chat that passed the per-chat cap.
struct CapBadge: View {
    let cap: Double

    var body: some View {
        Text("over \(Fmt.usd(cap).replacingOccurrences(of: ".00", with: ""))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.red)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.red.opacity(0.15)))
    }
}

/// Every chat this month over the per-chat cap, open or closed: where the money went.
struct OverCapSection: View {
    @ObservedObject var engine: GoldieEngine
    @State private var showAll = false

    private var chats: [CapChat] { engine.snapshot.overCapChats }
    private var shown: [CapChat] { showAll ? chats : Array(chats.prefix(5)) }

    private var summary: String {
        let total = chats.reduce(0) { $0 + $1.spentUSD }
        var line = "\(chats.count) chat\(chats.count == 1 ? "" : "s") · \(Fmt.usd(total))"
        if let month = engine.snapshot.monthUSD, month > 0 {
            line += " · \(Int((min(total / month, 1) * 100).rounded()))% of Cursor this month"
        }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Over the \(Fmt.usd(engine.config.chatCapUSD)) cap this month").font(.subheadline.weight(.semibold))
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { chat in
                HStack(spacing: 6) {
                    Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                        .font(.caption)
                        .lineLimit(1)
                    if chat.active {
                        Text("open").font(.caption2).foregroundStyle(.green)
                    }
                    Spacer()
                    Text(chat.active ? "" : Fmt.ago(chat.lastAt))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(Fmt.usd(chat.spentUSD))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.red)
                }
            }
            if chats.count > 5 {
                Button(showAll ? "Show fewer" : "Show all \(chats.count)") {
                    withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.06)))
        .help("Chats that cost more than chatCapUSD this month. Sub-task chats count toward their parent.")
    }
}
