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
    /// Blonde → ginger → brunette → almost black.
    static let hair: [(Double, Double, Double)] = [
        (0.92, 0.78, 0.44),
        (0.78, 0.42, 0.18),
        (0.42, 0.28, 0.15),
        (0.10, 0.08, 0.06),
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
/// everything static (face, hair, glasses, cigarette) draws once into a
/// cached Canvas, and only the smoke — present only while `cigarette` is on —
/// animates, in its own 30fps TimelineView so a lit cigarette never forces
/// the head itself to redraw.
struct AvatarHeadView: View {
    var skin: Color
    var hairColor: Color
    var hairstyle: Avatar.Hairstyle
    var glasses: Bool
    var cigarette: Bool
    var size: CGFloat
    /// Small list/badge renders skip the smoke entirely — no TimelineView,
    /// no per-frame work; the cigarette itself still shows.
    var animated: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(avatar: Avatar, size: CGFloat, animated: Bool = true) {
        skin = AvatarPalette.color(AvatarPalette.skin, at: avatar.skinTone)
        hairColor = AvatarPalette.color(AvatarPalette.hair, at: avatar.hair)
        hairstyle = avatar.hairstyle
        glasses = avatar.glasses
        cigarette = avatar.cigarette
        self.size = size
        self.animated = animated
    }

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

        switch hairstyle {
        case .spiky:
            // Bottom corners sit exactly on the face side edges
            // (x = 90 + 20/7 and 30 - 20/7 at y=40) so the hair seams with
            // the face silhouette — not rounded to integers on purpose.
            context.fill(g.polygon([
                (60, 2), (95, 18), (90 + 20.0 / 7, 40), (75, 35),
                (60, 38), (45, 35), (30 - 20.0 / 7, 40), (25, 18),
            ]), with: .color(hairColor))
        case .bowl:
            var cap = Path()
            cap.move(to: g.p(40, 5))
            cap.addLine(to: g.p(80, 5))
            cap.addQuadCurve(to: g.p(92, 18), control: g.p(92, 5))
            cap.addLine(to: g.p(92, 28))
            cap.addLine(to: g.p(28, 28))
            cap.addLine(to: g.p(28, 18))
            cap.addQuadCurve(to: g.p(40, 5), control: g.p(28, 5))
            cap.closeSubpath()
            context.fill(cap, with: .color(hairColor))

            var burns = context
            burns.opacity = 0.8
            burns.fill(g.polygon([(28, 28), (27, 45), (35, 40), (35, 28)]),
                       with: .color(hairColor))
            burns.fill(g.polygon([(92, 28), (93, 45), (85, 40), (85, 28)]),
                       with: .color(hairColor))

            var part = context
            part.opacity = 0.4
            var line = Path()
            line.move(to: g.p(60, 5))
            line.addLine(to: g.p(60, 24))
            part.stroke(line, with: .color(hairColor), lineWidth: 2 * g.s)
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

/// Buddy-list presence badge: the avatar itself is the status indicator.
/// Full color means online; greyscale means offline; away and idle get a
/// yellow duotone. Falls back to the default look for users who haven't set
/// an avatar. Never animates — these appear by the dozen in lists.
struct PresenceAvatar: View {
    let avatar: Avatar?
    let state: PresenceState
    var size: CGFloat = 32

    var body: some View {
        let head = AvatarHeadView(avatar: avatar ?? Avatar(), size: size, animated: false)
        switch state {
        case .online:
            head
        case .offline:
            head.grayscale(1).opacity(0.55)
        case .away, .idle:
            head.grayscale(1)
                .colorMultiply(Color(red: 1, green: 0.84, blue: 0.35))
        }
    }
}

/// Maps the design's viewBox ("20 0 80 85", aspect-fit centered) into canvas
/// points.
private struct AvatarGeometry {
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
