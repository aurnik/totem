import SwiftUI
import TotemKit

/// Draw on the settings preview with a finger. Committed strokes live on the
/// avatar itself and are drawn by `AvatarHeadView` exactly as friends will
/// see them; this view only draws the stroke in progress on top, then
/// simplifies and quantises it into the avatar on release and commits once
/// per stroke, the way the sliders commit once per drag.
struct DoodleEditor: View {
    @Environment(AppModel.self) private var model
    let size: CGFloat

    @State private var color = 0
    @State private var live: [CGPoint] = []
    /// What Clear removed, so one Undo brings it all back.
    @State private var cleared: [Doodle.Stroke]?
    @State private var edits = 0

    private var strokes: [Doodle.Stroke] { model.avatarSetting.doodle?.strokes ?? [] }

    private var isFull: Bool {
        guard let doodle = model.avatarSetting.doodle else { return false }
        return doodle.strokes.count >= Doodle.maxStrokes || doodle.pointCount >= Doodle.maxPoints
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                AvatarHeadView(avatar: model.avatarSetting, size: size)
                Canvas { context, canvasSize in
                    guard !live.isEmpty else { return }
                    context.stroke(DoodleBrush.path(through: live),
                                   with: .color(DoodlePalette.color(color)),
                                   style: DoodleBrush.style(AvatarGeometry(canvasSize)))
                }
                .allowsHitTesting(false)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .highPriorityGesture(drawing)

            HStack(spacing: 10) {
                ForEach(DoodlePalette.colors.indices, id: \.self) { index in
                    swatch(index)
                }
            }

            HStack {
                Button("Undo") { undo() }
                    .disabled(strokes.isEmpty && cleared == nil)
                Spacer()
                if isFull {
                    Text("Doodle is full")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Clear") { clear() }
                    .disabled(strokes.isEmpty)
            }
            .buttonStyle(.borderless)
        }
        .sensoryFeedback(.selection, trigger: color)
        .sensoryFeedback(.impact(weight: .light), trigger: edits)
    }

    private func swatch(_ index: Int) -> some View {
        Button { color = index } label: {
            Circle()
                .fill(DoodlePalette.color(index))
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .padding(3)
                .overlay(
                    Circle().stroke(Color.primary, lineWidth: 2)
                        .opacity(index == color ? 1 : 0)
                )
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }

    private var drawing: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                let point = drag.location
                if let last = live.last, hypot(point.x - last.x, point.y - last.y) < 2 {
                    return
                }
                live.append(point)
            }
            .onEnded { _ in
                commit(live)
                live = []
            }
    }

    private func commit(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        var doodle = model.avatarSetting.doodle ?? Doodle()
        let room = Doodle.maxPoints - doodle.pointCount
        guard doodle.strokes.count < Doodle.maxStrokes, room > 0 else { return }

        let g = AvatarGeometry(CGSize(width: size, height: size))
        var grid: [Int] = []
        var last: (x: Int, y: Int)?
        for point in Polyline.simplified(points, tolerance: 1) {
            let cell = g.grid(point)
            if let last, last == cell { continue }
            grid.append(cell.x)
            grid.append(cell.y)
            last = cell
        }
        doodle.strokes.append(.init(color: color, points: Array(grid.prefix(room * 2))))
        cleared = nil
        save(doodle)
    }

    private func undo() {
        if var doodle = model.avatarSetting.doodle, !doodle.strokes.isEmpty {
            doodle.strokes.removeLast()
            save(doodle)
        } else if let cleared {
            self.cleared = nil
            save(Doodle(strokes: cleared))
        }
    }

    private func clear() {
        cleared = strokes
        save(Doodle())
    }

    /// An empty doodle is stored as none at all, so the key leaves the wire.
    private func save(_ doodle: Doodle) {
        model.avatarSetting.doodle = doodle.strokes.isEmpty ? nil : doodle
        model.commitAvatar()
        edits += 1
    }
}

enum Polyline {
    /// Ramer-Douglas-Peucker: keeps the points that bend the line by more
    /// than `tolerance`, which is what makes a stroke cheap on the wire
    /// without changing its shape.
    static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let a = points[0], b = points[points.count - 1]
        var farthest: (index: Int, distance: CGFloat) = (0, 0)
        for i in 1..<(points.count - 1) {
            let d = distance(from: points[i], toLineThrough: a, b)
            if d > farthest.distance { farthest = (i, d) }
        }
        guard farthest.distance > tolerance else { return [a, b] }
        let head = simplified(Array(points[...farthest.index]), tolerance: tolerance)
        let tail = simplified(Array(points[farthest.index...]), tolerance: tolerance)
        return head + tail.dropFirst()
    }

    private static func distance(from p: CGPoint, toLineThrough a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }
}
