import GoldieCore
import SwiftUI

// MARK: - Root

struct GoldieRootView: View {
    @ObservedObject var engine: GoldieEngine
    let mover: WindowMover

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer(minLength: 0)
            if engine.expanded {
                DetailsCard(engine: engine)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let toast = engine.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .foregroundStyle(.white)
            }
            if let speech = engine.speech {
                SpeechBubble(text: speech.text)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if let target = engine.nudgeTarget {
                    FreshBowl()
                        .onTapGesture { engine.copyHandoff(threadID: target) }
                        .help("Copy a handoff prompt and start a fresh thread")
                        .transition(.scale.combined(with: .opacity))
                }
                BowlView(state: engine.bowl)
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { _ in mover.drag() }
                            .onEnded { _ in mover.end() }
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) { engine.expanded.toggle() }
                    }
            }
        }
        .padding(10)
        .frame(width: PanelController.size.width, height: PanelController.size.height, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.25), value: engine.nudgeTarget)
        .animation(.easeInOut(duration: 0.25), value: engine.speech)
    }
}

// MARK: - Bowl

struct BowlView: View {
    let state: BowlState
    var size: CGFloat = 170

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Water(level: state.waterLevel, murk: state.murk, size: size)
                ForEach(0..<4, id: \.self) { i in bubble(i, t) }
                ForEach(0..<state.fryCount, id: \.self) { i in fry(i, t) }
                GoldieFish(mood: state.mood, puff: CGFloat(state.puff), t: t, bowl: size)
                // glass
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 3)
                Circle().trim(from: 0.56, to: 0.68)
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .padding(14)
                // rim
                Ellipse().stroke(Color.white.opacity(0.6), lineWidth: 3)
                    .frame(width: size * 0.55, height: size * 0.09)
                    .offset(y: -size * 0.46)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
    }

    private func bubble(_ i: Int, _ t: Double) -> some View {
        let speed = state.mood == .sleeping ? 0.1 : (state.mood == .alarmed ? 0.5 : 0.22)
        let phase = (t * speed + Double(i) * 0.27).truncatingRemainder(dividingBy: 1)
        let xs: [CGFloat] = [-0.22, 0.16, -0.05, 0.26]
        let x = xs[i % 4] * size + CGFloat(sin(t * 2 + Double(i))) * 3
        let y = size * 0.36 - CGFloat(phase) * size * 0.62
        let d = CGFloat(4 + i * 2)
        return Circle()
            .stroke(Color.white.opacity(0.65 * (1 - phase)), lineWidth: 1.3)
            .frame(width: d, height: d)
            .offset(x: x, y: y)
    }

    private func fry(_ i: Int, _ t: Double) -> some View {
        let s = t * (0.9 + Double(i) * 0.17) + Double(i) * 1.7
        let x = CGFloat(sin(s)) * size * 0.3
        let y = size * 0.2 + CGFloat(cos(s * 1.3)) * size * 0.08
        return ZStack {
            Ellipse().fill(Color(red: 1, green: 0.55, blue: 0.2)).frame(width: 14, height: 8)
            Circle().fill(Color.black).frame(width: 3, height: 3).offset(x: 3, y: -1)
        }
        .scaleEffect(x: cos(s) > 0 ? 1 : -1, y: 1)
        .offset(x: x, y: y)
    }
}

struct Water: View {
    let level: Double
    let murk: Double
    let size: CGFloat

    var body: some View {
        let m = clamp01(murk)
        let color = Color(red: 0.55 + (0.42 - 0.55) * m, green: 0.82 + (0.52 - 0.82) * m, blue: 0.98 + (0.26 - 0.98) * m)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(LinearGradient(colors: [color.opacity(0.55 + 0.2 * m), color.opacity(0.8 + 0.15 * m)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: size * CGFloat(0.8 * clamp01(level)))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Goldie

/// Pop-funk (vinyl-figure) goldfish: oversized glossy eye, chunky fins, saturated orange.
struct GoldieFish: View {
    let mood: Mood
    let puff: CGFloat
    let t: Double
    let bowl: CGFloat

    var body: some View {
        let m = motion()
        FishBody(eyesClosed: mood == .sleeping, worried: mood == .alarmed || mood == .stressed, t: t)
            .scaleEffect(x: m.facingRight ? 1 : -1, y: 1)
            .scaleEffect(puff * bowl / 230)
            .rotationEffect(.degrees(m.tilt))
            .offset(x: m.x, y: m.y)
    }

    private struct Motion {
        var x: CGFloat
        var y: CGFloat
        var facingRight: Bool
        var tilt: Double
    }

    private func motion() -> Motion {
        let r = bowl
        switch mood {
        case .sleeping:  // drifting near the bottom
            return Motion(x: CGFloat(sin(t * 0.3)) * 6, y: r * 0.2 + CGFloat(sin(t * 0.8)) * 2, facingRight: true, tilt: -6)
        case .working:  // lazy laps
            let s = t * 0.6
            return Motion(x: CGFloat(sin(s)) * r * 0.2, y: r * 0.06 + CGFloat(sin(t * 1.3)) * 5, facingRight: cos(s) > 0, tilt: sin(t * 1.3) * 4)
        case .heavy:  // bloated and slow
            let s = t * 0.28
            return Motion(x: CGFloat(sin(s)) * r * 0.1, y: r * 0.12 + CGFloat(sin(t * 0.7)) * 3, facingRight: cos(s) > 0, tilt: 8)
        case .alarmed:  // tight frantic circles
            let s = t * 3.2
            return Motion(x: CGFloat(cos(s)) * r * 0.18, y: r * 0.06 + CGFloat(sin(s)) * r * 0.1, facingRight: -sin(s) > 0, tilt: 0)
        case .stressed:  // pressed against the glass
            return Motion(x: r * 0.2 + CGFloat(sin(t * 6)) * 2, y: r * 0.22, facingRight: true, tilt: -10)
        case .celebrating:  // flips
            let j = abs(sin(t * 4))
            return Motion(x: CGFloat(sin(t * 1.2)) * r * 0.1, y: r * 0.05 - CGFloat(j) * r * 0.25, facingRight: cos(t * 1.2) > 0, tilt: sin(t * 4) * 25)
        }
    }
}

struct FishBody: View {
    let eyesClosed: Bool
    let worried: Bool
    let t: Double

    private let orange = Color(red: 1.0, green: 0.50, blue: 0.10)
    private let light = Color(red: 1.0, green: 0.74, blue: 0.30)

    var body: some View {
        ZStack {
            TailShape()
                .fill(LinearGradient(colors: [light, orange], startPoint: .leading, endPoint: .trailing))
                .frame(width: 40, height: 50)
                .scaleEffect(x: 1, y: 0.85 + 0.15 * CGFloat(sin(t * 7)), anchor: .trailing)
                .offset(x: -50)
            Ellipse().fill(orange)  // dorsal fin
                .frame(width: 30, height: 16)
                .rotationEffect(.degrees(-20))
                .offset(x: -6, y: -34)
            Ellipse()  // body
                .fill(RadialGradient(colors: [light, orange], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 2, endRadius: 56))
                .frame(width: 92, height: 76)
            Ellipse().fill(Color.white.opacity(0.22))  // vinyl sheen
                .frame(width: 42, height: 14)
                .offset(x: 2, y: -24)
            Ellipse().fill(light)  // side fin
                .frame(width: 22, height: 12)
                .rotationEffect(.degrees(30 + 12 * sin(t * 5)))
                .offset(x: -8, y: 16)
            eye.offset(x: 20, y: -8)
            Ellipse().fill(Color.pink.opacity(0.5))  // blush
                .frame(width: 12, height: 7)
                .offset(x: 30, y: 12)
            mouth.offset(x: 42, y: 6)
        }
        .frame(width: 150, height: 100)
    }

    @ViewBuilder private var eye: some View {
        if eyesClosed {
            Capsule().fill(Color.black).frame(width: 18, height: 3.5)
        } else {
            ZStack {
                Circle().fill(Color.black).frame(width: 28, height: 28)
                Circle().fill(Color.white).frame(width: 9, height: 9).offset(x: -6, y: -6)
                Circle().fill(Color.white.opacity(0.7)).frame(width: 4, height: 4).offset(x: 6, y: 6)
            }
        }
    }

    @ViewBuilder private var mouth: some View {
        if worried {
            Circle().stroke(Color.black.opacity(0.8), lineWidth: 2).frame(width: 7, height: 7)
        } else {
            Circle().trim(from: 0.1, to: 0.4)
                .stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 10, height: 10)
        }
    }
}

struct TailShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: r.minY + r.height * 0.15))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.3, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.midX, y: r.maxY - r.height * 0.15))
        p.closeSubpath()
        return p
    }
}

// MARK: - Nudge pieces

/// The silent nudge: an empty bowl of clean water. Click = copy handoff.
struct FreshBowl: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let pulse = 1 + 0.04 * CGFloat(sin(timeline.date.timeIntervalSinceReferenceDate * 3))
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    Water(level: 0.95, murk: 0, size: 64)
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 2)
                }
                .frame(width: 64, height: 64)
                .scaleEffect(pulse)
                Text("fresh water?")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
            }
            .contentShape(Rectangle())
        }
    }
}

struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .padding(.trailing, 40)
    }
}

// MARK: - Details

struct DetailsCard: View {
    @ObservedObject var engine: GoldieEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Goldie").font(.system(.headline, design: .rounded))
                Text(engine.verdict.mood.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(moodColor.opacity(0.25)))
                Spacer()
                Text("brain: \(engine.brainStatus)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(engine.verdict.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let hint = engine.emptyHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if !engine.snapshot.threads.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(engine.snapshot.threads) { thread in
                            ThreadRow(thread: thread, isTarget: thread.id == engine.verdict.targetThread, engine: engine)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
            if engine.verdict.targetThread != nil || engine.verdict.mood == .alarmed {
                Button("Not helpful") { engine.notHelpful() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 350, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var moodColor: Color {
        switch engine.verdict.mood {
        case .alarmed: return .red
        case .heavy, .stressed: return .orange
        case .celebrating: return .green
        case .working: return .blue
        case .sleeping: return .gray
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSnapshot
    let isTarget: Bool
    @ObservedObject var engine: GoldieEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if thread.running { Text("running").font(.caption2).foregroundStyle(.secondary) }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Copy handoff") { engine.copyHandoff(threadID: thread.id) }
                Button("Snooze") { engine.snooze(threadID: thread.id) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isTarget ? Color.orange.opacity(0.18) : Color.primary.opacity(0.05)))
    }

    private var detail: String {
        let approx = thread.contextSource == "estimated" ? "~" : ""
        var parts = [
            thread.model ?? "model ?",
            "\(approx)\(thread.contextTokens / 1000)k ctx",
            String(format: "%.1f× fresh", thread.contextRatio),
            "loop \(Int(thread.loopScore * 100))%",
        ]
        if thread.maxMode { parts.append("MAX") }
        if let cost = thread.nextTurnCostUSD { parts.append(String(format: "$%.3f/turn", cost)) }
        return parts.joined(separator: " · ")
    }

    private var dotColor: Color {
        if thread.loopScore >= 0.75 || thread.contextRatio >= engine.config.alarmedRatio { return .red }
        if thread.loopScore >= 0.5 || thread.contextRatio >= engine.config.heavyRatio { return .orange }
        return .green
    }
}
