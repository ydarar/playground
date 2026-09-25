import GoldieCore
import SwiftUI

// MARK: - Formatting

enum Fmt {
    static func usd(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v > 0 && v < 0.01 { return "<$0.01" }
        return v < 100 ? String(format: "$%.2f", v) : String(format: "$%.0f", v)
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    static func idle(_ since: Date, now: Date = Date()) -> String {
        let m = Int(now.timeIntervalSince(since) / 60)
        return m < 1 ? "just now" : "idle \(m)m"
    }
}

extension Mood {
    /// Human wording for the mood chip and menu.
    var label: String {
        switch self {
        case .sleeping: return "Napping"
        case .working: return "All good"
        case .heavy: return "Getting heavy"
        case .alarmed: return "Needs you"
        case .stressed: return "Over budget pace"
        case .celebrating: return "Fresh start!"
        }
    }

    var color: Color {
        switch self {
        case .alarmed: return .red
        case .heavy, .stressed: return .orange
        case .celebrating: return .green
        case .working: return .blue
        case .sleeping: return .gray
        }
    }
}

// MARK: - Bowl

struct BowlView: View {
    let state: BowlState
    let paused: Bool
    var size: CGFloat = 170
    /// Goldie wiggles a little when you hover.
    var hovering: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 30 fps is plenty for a pet; 8 fps asleep; 6 fps with Reduce Motion; nothing while hidden.
    private var frameInterval: Double {
        if reduceMotion { return 1.0 / 6 }
        return state.mood == .sleeping ? 1.0 / 8 : 1.0 / 30
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    Water(level: state.waterLevel, murk: state.murk, size: size)
                    sand
                    plant(t)
                    // Murk = drifting specks (a heavy chat), not green water.
                    ForEach(0..<speckCount, id: \.self) { i in speck(i, t) }
                    ForEach(0..<4, id: \.self) { i in bubble(i, t) }
                    ForEach(0..<state.fryCount, id: \.self) { i in fry(i, t) }
                    GoldieFish(mood: state.mood, puff: CGFloat(state.puff), t: t, bowl: size, hovering: hovering)
                }
                .clipShape(Circle())
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
            .background(alignment: .bottom) {  // grounds the bowl on the desk
                Ellipse()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: size * 0.62, height: size * 0.07)
                    .blur(radius: 4)
                    .offset(y: size * 0.03)
            }
            .contentShape(Circle())
        }
    }

    private var speckCount: Int { Int((clamp01(state.murk) * 16).rounded()) }

    /// Fixed pseudo-random spots so specks don't jump around between frames.
    private func speck(_ i: Int, _ t: Double) -> some View {
        let rx = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let ry = abs(sin(Double(i) * 78.233) * 12345.678).truncatingRemainder(dividingBy: 1)
        let x = CGFloat(rx - 0.5) * size * 0.72 + CGFloat(sin(t * 0.25 + Double(i))) * 4
        let y = CGFloat(ry * 0.6 - 0.15) * size + CGFloat(cos(t * 0.2 + Double(i) * 1.3)) * 3
        let d = CGFloat(2 + i % 3)
        return Circle()
            .fill(Color(red: 0.45, green: 0.42, blue: 0.28).opacity(0.55))
            .frame(width: d, height: d)
            .offset(x: x, y: y)
    }

    private var sand: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.84, blue: 0.64), Color(red: 0.82, green: 0.70, blue: 0.50)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.95, height: size * 0.26)
                .offset(y: size * 0.44)
            Ellipse().fill(Color.gray.opacity(0.55)).frame(width: 9, height: 6).offset(x: size * 0.12, y: size * 0.36)
            Ellipse().fill(Color(red: 0.55, green: 0.5, blue: 0.6).opacity(0.6)).frame(width: 7, height: 5).offset(x: size * 0.2, y: size * 0.38)
            Ellipse().fill(Color.white.opacity(0.5)).frame(width: 6, height: 4).offset(x: -size * 0.05, y: size * 0.39)
        }
    }

    private func plant(_ t: Double) -> some View {
        let green = Color(red: 0.24, green: 0.62, blue: 0.36)
        return ZStack(alignment: .bottom) {
            Capsule().fill(green)
                .frame(width: 6, height: size * 0.22)
                .rotationEffect(.degrees(sin(t * 0.8) * 6 - 8), anchor: .bottom)
            Capsule().fill(green.opacity(0.85))
                .frame(width: 5, height: size * 0.16)
                .rotationEffect(.degrees(sin(t * 0.9 + 1) * 7 + 14), anchor: .bottom)
        }
        .frame(width: 30, height: size * 0.24, alignment: .bottom)
        .offset(x: -size * 0.27, y: size * 0.24)
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
        // Stays water-colored when murky (a slight grey-teal), the specks carry the "dirty" signal.
        let m = clamp01(murk)
        let color = Color(red: 0.56 + (0.52 - 0.56) * m, green: 0.82 + (0.72 - 0.82) * m, blue: 0.97 + (0.74 - 0.97) * m)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(LinearGradient(colors: [color.opacity(0.5 + 0.1 * m), color.opacity(0.75 + 0.1 * m)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {  // water surface
                    Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1.5)
                }
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
    var hovering: Bool = false

    /// A quick blink every few seconds keeps her alive.
    private var blinking: Bool { t.truncatingRemainder(dividingBy: 4.7) < 0.14 }

    var body: some View {
        let m = motion()
        FishBody(eyesClosed: mood == .sleeping || blinking, worried: mood == .alarmed || mood == .stressed, t: t)
            .scaleEffect(x: m.facingRight ? 1 : -1, y: 1)
            .scaleEffect(puff * bowl / 330)
            .rotationEffect(.degrees(m.tilt + (hovering ? sin(t * 14) * 5 : 0)))
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
            return Motion(x: CGFloat(sin(t * 0.3)) * 6, y: r * 0.22 + CGFloat(sin(t * 0.8)) * 2, facingRight: true, tilt: -6)
        case .working:  // lazy laps
            let s = t * 0.6
            return Motion(x: CGFloat(sin(s)) * r * 0.18, y: r * 0.08 + CGFloat(sin(t * 1.3)) * 5, facingRight: cos(s) > 0, tilt: sin(t * 1.3) * 4)
        case .heavy:  // bloated and slow
            let s = t * 0.28
            return Motion(x: CGFloat(sin(s)) * r * 0.1, y: r * 0.14 + CGFloat(sin(t * 0.7)) * 3, facingRight: cos(s) > 0, tilt: 8)
        case .alarmed:  // tight frantic circles
            let s = t * 3.2
            return Motion(x: CGFloat(cos(s)) * r * 0.16, y: r * 0.1 + CGFloat(sin(s)) * r * 0.08, facingRight: -sin(s) > 0, tilt: 0)
        case .stressed:  // pressed against the glass
            return Motion(x: r * 0.18 + CGFloat(sin(t * 6)) * 2, y: r * 0.22, facingRight: true, tilt: -10)
        case .celebrating:  // flips
            let j = abs(sin(t * 4))
            return Motion(x: CGFloat(sin(t * 1.2)) * r * 0.1, y: r * 0.08 - CGFloat(j) * r * 0.2, facingRight: cos(t * 1.2) > 0, tilt: sin(t * 4) * 25)
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
