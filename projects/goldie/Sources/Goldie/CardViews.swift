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
                if let target = engine.focusThread {
                    FreshBowl(paused: !engine.panelVisible, title: engine.snapshot.thread(target)?.title)
                        .onTapGesture { engine.copyHandoff(threadID: target) }
                        .help("Start fresh: copies a handoff prompt, then brings Cursor forward so you can paste it into a new chat")
                        .transition(.scale.combined(with: .opacity))
                }
                BowlView(state: engine.bowl, paused: !engine.panelVisible, size: CGFloat(engine.bowlSize))
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { _ in mover.drag() }
                            .onEnded { _ in mover.end() }
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) { engine.expanded.toggle() }
                    }
                    .onHover { hovering = $0 }
            }
        }
        .padding(10)
        .frame(width: PanelController.size.width, height: PanelController.size.height, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.25), value: engine.focusThread)
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
        if t.loopScore >= 0.5 || t.contextRatio >= config.heavyRatio { return 1 }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if engine.needsSetup { SetupChecklist(engine: engine) }
            BudgetSection(snapshot: engine.snapshot, budget: engine.config.monthlyBudgetUSD, usageStatus: engine.usageStatus)
            goldieSays
            threadList
            footer
            if showLegend { Legend() }
        }
        .padding(14)
        .frame(width: 350, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
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
                withAnimation(.spring(response: 0.3)) { engine.expanded = false }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
    }

    /// Goldie's verdict in one sentence, plus the one action that matters.
    private var goldieSays: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("🐠")
            VStack(alignment: .leading, spacing: 8) {
                Text(engine.verdict.reason)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let selected = engine.selectedThread, selected != engine.nudgeTarget,
                   let chat = engine.snapshot.thread(selected) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected: “\(chat.title)”").font(.caption.weight(.semibold)).lineLimit(1)
                        Button("Start fresh for this chat") { engine.copyHandoff(threadID: selected) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.orange)
                    }
                } else if let target = engine.nudgeTarget {
                    HStack(spacing: 10) {
                        Button("Start fresh") { engine.copyHandoff(threadID: target) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.orange)
                            .help("Copies a handoff prompt and brings Cursor forward. Paste it into a new chat.")
                        Button("Not now") { engine.snooze(threadID: target) }
                            .help("Goldie won't nudge about this chat for \(Int(engine.config.snoozeMinutes)) minutes")
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button("Not helpful") { engine.notHelpful() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(engine.verdict.mood.color.opacity(0.12)))
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
            let rows = VStack(spacing: 6) {
                ForEach(sortedThreads) { thread in
                    ThreadRow(thread: thread,
                              isTarget: thread.id == engine.nudgeTarget,
                              isSelected: thread.id == engine.selectedThread,
                              engine: engine)
                }
            }
            if engine.snapshot.threads.count > 2 {
                ScrollView { rows }.frame(height: 250)
            } else {
                rows
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(engine.snapshot.threads.count) chat(s) · updates every \(Int(engine.config.pollSeconds))s")
                .foregroundStyle(.secondary)
            Spacer()
            Button(showLegend ? "Hide explanations" : "What do these mean?") {
                withAnimation(.easeInOut(duration: 0.2)) { showLegend.toggle() }
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

/// Spend vs budget, with a tick for where even spending would put you today.
struct BudgetSection: View {
    let snapshot: Snapshot
    let budget: Double
    let usageStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cursor this month").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(headline)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            BudgetBar(spent: spentFraction, pace: paceFraction, color: barColor)
                .frame(height: 8)
            Text(subline).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        guard let month = snapshot.monthUSD else { return "—" }
        return "\(Fmt.usd(month)) of \(Fmt.usd(budget))"
    }

    private var spentFraction: Double {
        guard let month = snapshot.monthUSD, budget > 0 else { return 0 }
        return month / budget
    }

    private var paceFraction: Double {
        let now = Date()
        guard let month = Calendar.current.dateInterval(of: .month, for: now) else { return 0 }
        return now.timeIntervalSince(month.start) / month.duration
    }

    private var barColor: Color {
        if let projected = snapshot.projectedMonthUSD, projected > budget { return .red }
        if spentFraction > paceFraction { return .orange }
        return .green
    }

    private var subline: String {
        guard snapshot.monthUSD != nil else { return "Costs not connected: \(usageStatus)" }
        var parts = ["Today \(Fmt.usd(snapshot.todayUSD))"]
        if let projected = snapshot.projectedMonthUSD { parts.append("on pace for ~\(Fmt.usd(projected)) this month") }
        return parts.joined(separator: " · ")
    }
}

struct BudgetBar: View {
    let spent: Double
    let pace: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(clamp01(spent))))
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: geo.size.width * CGFloat(clamp01(pace)) - 1)
            }
        }
        .help("Bar: spent vs budget. Tick: where you'd be today if you spent evenly all month.")
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
                    Spacer()
                    Text(thread.running ? "running" : Fmt.idle(thread.lastActivity))
                        .font(.caption2)
                        .foregroundStyle(thread.running ? Color.green : Color.secondary)
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ContextMeter(label: meterLabel, fraction: clamp01(thread.contextRatio / max(engine.config.alarmedRatio, 1)), color: color)
                if let advice = adviceLine {
                    Text(advice)
                        .font(.caption)
                        .foregroundStyle(severity == 0 ? Color.secondary : color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isSelected {
                    Button("Start fresh") { engine.copyHandoff(threadID: thread.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                } else {
                    Button("Start fresh") { engine.copyHandoff(threadID: thread.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
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

    /// "grok-4.7 · spent $4.10 · last msg $1.40 · ~$0.12/step"
    private var metaLine: String {
        var parts = [thread.model ?? "unknown model"]
        if thread.maxMode { parts.append("Max Mode") }
        if let spent = thread.spentUSD { parts.append("spent \(Fmt.usd(spent))") }
        if let last = thread.lastMessageUSD, last > 0 { parts.append("last msg \(Fmt.usd(last))") }
        if let step = thread.nextTurnCostUSD {
            parts.append("~\(Fmt.usd(step))/step" + (thread.costSource == "cursor" ? "" : " est."))
        }
        return parts.joined(separator: " · ")
    }

    private var meterLabel: String {
        let approx = thread.contextSource == "estimated" ? "~" : ""
        return "\(approx)\(Fmt.tokens(thread.contextTokens)) re-read/step"
    }

    /// The one thing worth knowing, in plain words.
    private var adviceLine: String? {
        if ModelPolicy.blockedKeyword(for: thread.model, keywords: engine.config.blockedModelKeywords) != nil {
            return "⛔︎ Uses \(thread.model ?? "a blocked model"), a Chinese-vendor model. Switch to an approved model."
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
        if thread.contextRatio >= 2 {
            return "A new chat would be ~\(Int(thread.contextRatio.rounded()))× cheaper per step."
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
            item("Spent · last msg · per step", "Real charges from your Cursor usage, matched to each chat by time. Close, not exact. \"est.\" = estimated from tokens.")
            item("Budget bar & water level", "Month spend vs your budget. The tick shows where even spending would put you today. Goldie's water drains as you spend.")
            item("Start fresh", "Copies a handoff (goal, files, where things stand) and brings Cursor forward. Paste it into a new chat.")
            item("Selecting a chat", "Click any chat to point the fresh bowl and Start fresh at it. Without a selection they follow Goldie's pick.")
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
