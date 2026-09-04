import SwiftUI
import TotemKit

/// Palette stops for the avatar sliders, as RGB triples so the same values
/// drive the gradient tracks, the knob previews, and avatar rendering.
enum AvatarPalette {
    /// Pale white → dark brown.
    static let skin: [(Double, Double, Double)] = [
        (0.98, 0.89, 0.80),
        (0.94, 0.80, 0.64),
        (0.83, 0.62, 0.42),
        (0.62, 0.42, 0.25),
        (0.42, 0.27, 0.16),
        (0.28, 0.18, 0.11),
    ]
    /// Blonde → ginger → brunette → almost black → greys, stopping at medium
    /// grey rather than running all the way to white.
    static let hair: [(Double, Double, Double)] = [
        (0.92, 0.78, 0.44),
        (0.78, 0.42, 0.18),
        (0.42, 0.28, 0.15),
        (0.10, 0.08, 0.06),
        (0.32, 0.32, 0.34),
        (0.55, 0.55, 0.57),
    ]

    static func colors(_ stops: [(Double, Double, Double)]) -> [Color] {
        stops.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }

    /// Piecewise-linear interpolation across the stops at `t` in 0…1.
    static func color(_ stops: [(Double, Double, Double)], at t: Double) -> Color {
        let clamped = min(max(t, 0), 1)
        let position = clamped * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        let fraction = position - Double(index)
        let (a, b) = (stops[index], stops[index + 1])
        return Color(
            red: a.0 + (b.0 - a.0) * fraction,
            green: a.1 + (b.1 - a.1) * fraction,
            blue: a.2 + (b.2 - a.2) * fraction)
    }
}

/// Flat, angular character head — the design's SVG geometry (viewBox
/// "20 0 80 85") rendered natively. Adapted from the original web component:
/// everything static (face, hair, glasses, cigarette, doodle) draws once into a
/// cached Canvas, and only the smoke — present only while `cigarette` is on —
/// animates, in its own 30fps TimelineView so a lit cigarette never forces
/// the head itself to redraw.
struct AvatarHeadView: View {
    var avatar: Avatar
    var size: CGFloat
    /// Small list/badge renders skip the smoke entirely — no TimelineView,
    /// no per-frame work; the cigarette itself still shows.
    var animated: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    private var skin: Color { AvatarPalette.color(AvatarPalette.skin, at: avatar.skinTone) }
    private var hairColor: Color { AvatarPalette.color(AvatarPalette.hair, at: avatar.hair) }
    private var glasses: Bool { avatar.glasses }
    private var cigarette: Bool { avatar.cigarette }

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                let g = AvatarGeometry(canvasSize)
                drawHead(in: &context, g: g)
            }
            if cigarette && animated {
                let smoke: Color = colorScheme == .dark
                    ? .white.opacity(0.7)
                    : Color(red: 35 / 255, green: 35 / 255, blue: 35 / 255).opacity(0.7)
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    Canvas { context, canvasSize in
                        let g = AvatarGeometry(canvasSize)
                        drawSmoke(
                            in: &context, g: g, color: smoke,
                            time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Static layers

    private func drawHead(in context: inout GraphicsContext, g: AvatarGeometry) {
        // Face: heptagon, no stroke.
        context.fill(g.polygon([
            (60, 5), (90, 20), (95, 55), (85, 80), (35, 80), (25, 55), (30, 20),
        ]), with: .color(skin))

        if avatar.longHair {
            // Parted in the middle: the crown dips to the part, the fringe sits
            // higher than the crop's, and the sides fall past the face to the
            // bottom of the box as strands of even width, bending three times
            // and leaning slightly outward. The outer corners sit just outside
            // the viewBox, in the margin the square frame leaves beside it.
            context.fill(g.polygon([
                (60, 6), (78, 2), (96, 16), (100, 32), (97, 50), (102, 68),
                (99, 85), (88, 85), (91, 68), (86, 50), (84, 33),
                (75, 35), (60, 31), (45, 35), (36, 33), (34, 50),
                (29, 68), (32, 85), (21, 85), (18, 68), (23, 50), (20, 32),
                (24, 16), (42, 2),
            ]), with: .color(hairColor))
        } else {
            // Bottom corners sit exactly on the face side edges
            // (x = 90 + 20/7 and 30 - 20/7 at y=40) so the hair seams with
            // the face silhouette — not rounded to integers on purpose.
            context.fill(g.polygon([
                (60, 2), (95, 18), (90 + 20.0 / 7, 40), (75, 35),
                (60, 38), (45, 35), (30 - 20.0 / 7, 40), (25, 18),
            ]), with: .color(hairColor))
        }

        // The doodle sits on the face and hair; glasses and the cigarette stay
        // on top of it, since they are things worn over a face, not drawn on it.
        if let doodle = avatar.doodle {
            for stroke in doodle.strokes {
                let points = stride(from: 0, to: stroke.points.count - 1, by: 2).map {
                    g.point(gridX: stroke.points[$0], gridY: stroke.points[$0 + 1])
                }
                context.stroke(DoodleBrush.path(through: points),
                               with: .color(DoodlePalette.color(stroke.color)),
                               style: DoodleBrush.style(g))
            }
        }

        if glasses {
            let frame = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
            let width = 4 * g.s
            context.stroke(Path(g.rect(32, 47, 22, 12)), with: .color(frame), lineWidth: width)
            context.stroke(Path(g.rect(66, 47, 22, 12)), with: .color(frame), lineWidth: width)
            var bridge = Path()
            bridge.move(to: g.p(54, 53))
            bridge.addLine(to: g.p(66, 53))
            context.stroke(bridge, with: .color(frame), lineWidth: width)
        }

        if cigarette {
            var tilted = context
            let pivot = g.p(75, 70)
            tilted.translateBy(x: pivot.x, y: pivot.y)
            tilted.rotate(by: .degrees(15))
            tilted.translateBy(x: -pivot.x, y: -pivot.y)
            tilted.fill(Path(g.rect(75, 66, 20, 7)),
                        with: .color(Color(red: 0.96, green: 0.96, blue: 0.94)))
            tilted.fill(Path(g.rect(92, 66, 5, 7)),
                        with: .color(Color(red: 0.88, green: 0.44, blue: 0.13)))
        }
    }

    // MARK: - Smoke (the web version's SMIL keyframes, interpolated per frame)

    /// A wavy stroke morphing between two coordinate sets (the SMIL A;B;A
    /// cycle): start point then quad-curve (control, end) pairs, flattened.
    private struct Wisp {
        let width: Double
        let duration: Double
        let opacities: (Double, Double)
        let a: [Double]
        let b: [Double]
    }

    private static let wisps: [Wisp] = [
        Wisp(width: 4, duration: 3, opacities: (0.7, 0.4),
             a: [97, 74, 99, 68, 97, 62, 95, 56, 98, 50, 101, 44, 99, 36, 97, 28, 100, 20],
             b: [97, 74, 95, 68, 98, 62, 101, 56, 98, 50, 95, 44, 98, 36, 101, 28, 98, 20]),
        Wisp(width: 3, duration: 2.5, opacities: (0.6, 0.3),
             a: [98, 73, 101, 66, 99, 58, 97, 50, 100, 42, 103, 34, 100, 26],
             b: [98, 73, 96, 66, 99, 58, 102, 50, 99, 42, 96, 34, 99, 26]),
        Wisp(width: 2, duration: 2, opacities: (0.5, 0.25),
             a: [96, 75, 98, 70, 96, 64, 94, 58, 97, 52, 100, 46, 97, 40],
             b: [96, 75, 94, 70, 97, 64, 100, 58, 97, 52, 94, 46, 97, 40]),
    ]

    /// Rising puffs: evenly spaced keyframes for cx, cy, opacity, radius.
    private struct Puff {
        let duration: Double
        let cx: [Double]
        let cy: [Double]
        let opacity: [Double]
        let radius: [Double]
    }

    private static let puffs: [Puff] = [
        Puff(duration: 2, cx: [97, 99, 96, 98], cy: [74, 50, 26, 10],
             opacity: [0.7, 0.4, 0.15, 0], radius: [1, 2, 3, 4]),
        Puff(duration: 2.3, cx: [98, 96, 100, 97], cy: [74, 55, 35, 15],
             opacity: [0.6, 0.35, 0.15, 0], radius: [1, 1.5, 2.5, 3.5]),
    ]

    private func drawSmoke(
        in context: inout GraphicsContext, g: AvatarGeometry, color: Color, time: Double
    ) {
        // The web version masked the smoke with a bottom-to-top fade
        // (1 → 0.5 at 60% → 0); a gradient stroke is the same thing cheaper.
        let fade = Gradient(stops: [
            .init(color: color, location: 0),
            .init(color: color.opacity(0.5), location: 0.6),
            .init(color: color.opacity(0), location: 1),
        ])
        let bottom = g.p(97, 80)
        let top = g.p(97, 10)

        for wisp in Self.wisps {
            let phase = (time / wisp.duration).truncatingRemainder(dividingBy: 1)
            // A;B;A cycle → triangle wave.
            let t = 1 - abs(2 * phase - 1)
            var path = Path()
            path.move(to: g.p(lerp(wisp.a[0], wisp.b[0], t), lerp(wisp.a[1], wisp.b[1], t)))
            for k in stride(from: 2, to: wisp.a.count, by: 4) {
                path.addQuadCurve(
                    to: g.p(lerp(wisp.a[k + 2], wisp.b[k + 2], t),
                            lerp(wisp.a[k + 3], wisp.b[k + 3], t)),
                    control: g.p(lerp(wisp.a[k], wisp.b[k], t),
                                 lerp(wisp.a[k + 1], wisp.b[k + 1], t)))
            }
            var layer = context
            layer.opacity = 0.85 * lerp(wisp.opacities.0, wisp.opacities.1, t)
            layer.stroke(
                path,
                with: .linearGradient(fade, startPoint: bottom, endPoint: top),
                style: StrokeStyle(lineWidth: wisp.width * g.s, lineCap: .round))
        }

        for puff in Self.puffs {
            let phase = (time / puff.duration).truncatingRemainder(dividingBy: 1)
            let cy = keyframe(puff.cy, phase)
            let center = g.p(keyframe(puff.cx, phase), cy)
            let radius = keyframe(puff.radius, phase) * g.s
            var layer = context
            layer.opacity = 0.85 * keyframe(puff.opacity, phase) * fadeAlpha(atY: cy)
            layer.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2)),
                with: .color(color))
        }
    }

    /// The mask gradient's alpha at a viewBox height (span y=80 down to 10).
    private func fadeAlpha(atY y: Double) -> Double {
        let location = min(max((80 - y) / 70, 0), 1)
        return location <= 0.6
            ? 1 - location / 0.6 * 0.5
            : 0.5 * (1 - (location - 0.6) / 0.4)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// SMIL-style evenly spaced linear keyframes.
    private func keyframe(_ values: [Double], _ phase: Double) -> Double {
        let position = phase * Double(values.count - 1)
        let index = min(Int(position), values.count - 2)
        return lerp(values[index], values[index + 1], position - Double(index))
    }
}

/// A user's avatar wherever one appears inline. Users who haven't published
/// one (a friend still on an older build) get nothing at all — the unset
/// default look is only ever shown to its owner, in settings.
struct UserAvatar: View {
    let avatar: Avatar?
    var size: CGFloat = 28
    /// Handle to fall back to when this user has published no avatar. Supply
    /// it only where the slot itself carries information — who is speaking,
    /// who a row is about — since losing it would lose that. Purely decorative
    /// slots leave it nil and render nothing, because a stand-in face would be
    /// a look its owner never chose.
    var monogram: String?

    var body: some View {
        if let avatar {
            AvatarHeadView(avatar: avatar, size: size, animated: false)
        } else if let monogram {
            MonogramCircle(handle: monogram, size: size)
        }
    }
}

/// Buddy-list presence badge: the avatar itself is the status indicator.
/// Full color means online; greyscale means offline; away and idle are
/// greyscale too, marked by a pair of rising Z's. Without a published avatar
/// it degrades to the colored state dot. Never animates — these appear by the
/// dozen in lists.
struct PresenceAvatar: View {
    let avatar: Avatar?
    let state: PresenceState
    var size: CGFloat = 32

    var body: some View {
        if let avatar {
            let head = AvatarHeadView(avatar: avatar, size: size, animated: false)
            switch state {
            case .online:
                head
            case .offline:
                head.grayscale(1).opacity(0.55)
            case .away, .idle:
                head.grayscale(1)
                    .overlay(SleepingZs())
            }
        } else {
            StateDot(state: state)
                .frame(width: size, height: size)
        }
    }
}

/// Two hand-drawn Z's rising to the right over an away buddy's greyscale
/// avatar; the nearer one is smaller. Haloed in the opposite ink so they stay
/// legible where they cross the head.
private struct SleepingZs: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height)
            let ink: Color = colorScheme == .dark ? .white : .black
            let halo: Color = colorScheme == .dark ? .black : .white
            for (x, y, side) in [(0.55, 0.33, 0.13), (0.74, 0.06, 0.21)] {
                let (left, right) = (x * unit, (x + side) * unit)
                let (top, bottom) = (y * unit, (y + side) * unit)
                var path = Path()
                path.move(to: CGPoint(x: left, y: top))
                path.addLine(to: CGPoint(x: right, y: top))
                path.addLine(to: CGPoint(x: left, y: bottom))
                path.addLine(to: CGPoint(x: right, y: bottom))
                let width = max(side * unit * 0.16, 1)
                context.stroke(path, with: .color(halo),
                               style: StrokeStyle(lineWidth: width * 2.2, lineCap: .round))
                context.stroke(path, with: .color(ink),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }
}

struct StateDot: View {
    let state: PresenceState

    var color: Color {
        switch state {
        case .online: .green
        case .away: .orange
        case .idle: .yellow
        case .offline: .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

/// Stands in for a missing avatar only where a row would otherwise be
/// anonymous — the live-audio meters carry no handle of their own.
struct MonogramCircle: View {
    let handle: String
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
            Text(handle.prefix(1).uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Maps the design's viewBox ("20 0 80 85", aspect-fit centered) into canvas
/// points.
struct AvatarGeometry {
    let s: CGFloat
    private let xOffset: CGFloat
    private let yOffset: CGFloat

    init(_ canvasSize: CGSize) {
        s = min(canvasSize.width / 80, canvasSize.height / 85)
        xOffset = (canvasSize.width - 80 * s) / 2 - 20 * s
        yOffset = (canvasSize.height - 85 * s) / 2
    }

    func p(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * s + xOffset, y: y * s + yOffset)
    }

    // The doodle grid spans the head's box, x 20…100 and y 0…85 in viewBox
    // units, so a drawing made at one size lands identically at every other.

    func point(gridX: Int, gridY: Int) -> CGPoint {
        let last = Double(Doodle.gridSize - 1)
        return p(20 + Double(gridX) / last * 80, Double(gridY) / last * 85)
    }

    func grid(_ point: CGPoint) -> (x: Int, y: Int) {
        let ux = ((point.x - xOffset) / s - 20) / 80
        let uy = (point.y - yOffset) / s / 85
        let last = Double(Doodle.gridSize - 1)
        return (Int((min(max(ux, 0), 1) * last).rounded()),
                Int((min(max(uy, 0), 1) * last).rounded()))
    }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s))
    }

    func polygon(_ points: [(Double, Double)]) -> Path {
        var path = Path()
        path.move(to: p(points[0].0, points[0].1))
        for point in points.dropFirst() {
            path.addLine(to: p(point.0, point.1))
        }
        path.closeSubpath()
        return path
    }
}

/// Monokai, in swatch order. Indexes are what the wire carries, so this
/// order is part of the protocol: append, never reorder.
enum DoodlePalette {
    static let colors: [Color] = [
        Color(red: 0xF9 / 255, green: 0x26 / 255, blue: 0x72 / 255),
        Color(red: 0xFD / 255, green: 0x97 / 255, blue: 0x1F / 255),
        Color(red: 0xE6 / 255, green: 0xDB / 255, blue: 0x74 / 255),
        Color(red: 0xA6 / 255, green: 0xE2 / 255, blue: 0x2E / 255),
        Color(red: 0x66 / 255, green: 0xD9 / 255, blue: 0xEF / 255),
        Color(red: 0xAE / 255, green: 0x81 / 255, blue: 0xFF / 255),
        Color(red: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF2 / 255),
        Color(red: 0x27 / 255, green: 0x28 / 255, blue: 0x22 / 255),
    ]

    static func color(_ index: Int) -> Color {
        colors[min(max(index, 0), colors.count - 1)]
    }
}

enum DoodleBrush {
    /// In viewBox units, so a stroke scales with the head it sits on; the
    /// floor keeps a doodle legible on the smallest list avatars.
    static let width: Double = 2.5

    static func style(_ g: AvatarGeometry) -> StrokeStyle {
        StrokeStyle(lineWidth: max(width * g.s, 1), lineCap: .round, lineJoin: .round)
    }

    /// Midpoint quadratics: every sample is a control point and the joints
    /// sit halfway between samples, so the tangent is continuous through each
    /// one and a finger-drawn line has no corners. A lone sample is a dot,
    /// which the round cap draws from a zero-length segment.
    static func path(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.last!)
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                              y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
