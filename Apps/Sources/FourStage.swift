import SwiftUI
import TotemKit

enum FourExtension: ChatExtension {
    static let id = ChatExtensionID.four
    static let name = "Four"
}

enum FourPalette {
    static let board = Color(red: 0.11, green: 0.36, blue: 0.80)
    static let red = Color(red: 0.86, green: 0.21, blue: 0.24)
    static let yellow = Color(red: 0.98, green: 0.78, blue: 0.19)

    static func disc(_ disc: FourDisc) -> Color {
        switch disc {
        case .red: Self.red
        case .yellow: Self.yellow
        }
    }
}

/// The menu glyph: a slab with four holes punched through. Even-odd is what
/// makes them holes rather than filled circles, and `Shape` carries no fill
/// rule of its own, so the caller must pass `FillStyle(eoFill: true)`.
struct FourBoardIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.24)
        let radius = min(rect.width, rect.height) * 0.16
        // Three equal gaps per axis: two margins plus the space between.
        let inset = CGPoint(x: (rect.width - 4 * radius) / 3, y: (rect.height - 4 * radius) / 3)
        for x in [rect.minX + inset.x + radius, rect.maxX - inset.x - radius] {
            for y in [rect.minY + inset.y + radius, rect.maxY - inset.y - radius] {
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
            }
        }
        return path
    }
}

/// Maps board coordinates onto a view's bounds, shared by the plate, the pieces
/// and the taps.
struct FourGeometry {
    let cell: CGFloat
    let radius: CGFloat
    let plate: CGRect
    /// The grid of holes, inset by the plate's border.
    let grid: CGRect

    init(_ size: CGSize) {
        // A border keeps the outer holes off the edge of the plate.
        let border = min(size.width, size.height) * 0.045
        cell = min((size.width - 2 * border) / CGFloat(FourState.columns),
                   (size.height - 2 * border) / CGFloat(FourState.rows))
        radius = cell * 0.38
        let holes = CGSize(width: cell * CGFloat(FourState.columns),
                           height: cell * CGFloat(FourState.rows))
        grid = CGRect(x: (size.width - holes.width) / 2, y: (size.height - holes.height) / 2,
                      width: holes.width, height: holes.height)
        plate = grid.insetBy(dx: -border, dy: -border)
    }

    /// Row 0 is the bottom of the board, inverted from view coordinates.
    func center(_ slot: FourSlot) -> CGPoint {
        CGPoint(x: grid.minX + (CGFloat(slot.column) + 0.5) * cell,
                y: grid.maxY - (CGFloat(slot.row) + 0.5) * cell)
    }

    func entry(column: Int) -> CGPoint {
        center(FourSlot(column: column, row: FourState.rows - 1))
    }
}

/// The blue plate, drawn over the pieces with an even-odd fill so the holes are
/// transparent and show the pieces, or the chat, behind them.
struct FourBoardPlate: Shape {
    func path(in rect: CGRect) -> Path {
        let geometry = FourGeometry(rect.size)
        var path = Path(roundedRect: geometry.plate, cornerRadius: geometry.cell * 0.45)
        for column in 0..<FourState.columns {
            for row in 0..<FourState.rows {
                let center = geometry.center(FourSlot(column: column, row: row))
                path.addEllipse(in: CGRect(x: center.x - geometry.radius,
                                           y: center.y - geometry.radius,
                                           width: geometry.radius * 2,
                                           height: geometry.radius * 2))
            }
        }
        return path
    }
}

/// A game of Connect 4 everyone in the chat watches and two of them play.
/// Nothing is applied locally: a tap sends a drop and the board only moves when
/// the stage's owner says it did.
struct FourStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageBox) private var stageBox
    let conversationID: UUID
    let four: FourState

    private static let boardRatio = CGFloat(FourState.columns) / CGFloat(FourState.rows)
    private static let railWidth: CGFloat = 40
    private static let railSpacing: CGFloat = 10
    private static let seatSize: CGFloat = 34
    /// Both rails plus the view's horizontal padding: the width the board loses.
    private static let boardInset = 24 + 2 * (railWidth + railSpacing)

    /// Nil unless the conversation is too short for the board's full width; a
    /// cap bigger than the board would be claimed as an empty band.
    private var boardCap: CGFloat? {
        guard stageBox.width > 0 else { return nil }
        let natural = (stageBox.width - Self.boardInset) / Self.boardRatio
        return stageBox.height < natural ? stageBox.height : nil
    }

    /// The piece currently falling, drawn separately so it can be animated. The
    /// board skips its slot until it lands.
    private struct Landing: Equatable {
        var slot: FourSlot
        var disc: FourDisc
        var settled = false
    }

    @State private var landing: Landing?

    private var me: UUID? { model.currentUser?.id }

    private var isMyTurn: Bool {
        four.outcome == nil && four.yellow != nil && four.player(four.turn) == me
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: Self.railSpacing) {
                rail(.red)
                GeometryReader { proxy in
                    let geometry = FourGeometry(proxy.size)
                    ZStack {
                        pieces(geometry)
                        fallingPiece(geometry)
                        FourBoardPlate().fill(FourPalette.board, style: FillStyle(eoFill: true))
                        winLine(geometry)
                        columns(geometry)
                    }
                }
                .aspectRatio(Self.boardRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: boardCap)
                rail(.yellow)
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: four) { old, new in noteDrop(from: old, to: new) }
        .task(id: four.finishedAt) { await expireWhenTimeIsUp() }
    }

    // MARK: - Board

    private func pieces(_ geometry: FourGeometry) -> some View {
        ForEach(0..<FourState.columns, id: \.self) { column in
            ForEach(Array(four.stacks[column].enumerated()), id: \.offset) { row, disc in
                let slot = FourSlot(column: column, row: row)
                if landing?.slot != slot {
                    piece(disc, geometry).position(geometry.center(slot))
                }
            }
        }
    }

    @ViewBuilder
    private func fallingPiece(_ geometry: FourGeometry) -> some View {
        if let landing {
            piece(landing.disc, geometry)
                .position(landing.settled
                          ? geometry.center(landing.slot)
                          : geometry.entry(column: landing.slot.column))
                .opacity(landing.settled ? 1 : 0)
                // Keyed to the slot so a second drop landing before the first has
                // cleared still gets its own appearance, and its own animation.
                .id(landing.slot)
                .onAppear { drop(landing) }
        }
    }

    private func piece(_ disc: FourDisc, _ geometry: FourGeometry) -> some View {
        Circle()
            .fill(FourPalette.disc(disc))
            .frame(width: geometry.radius * 2, height: geometry.radius * 2)
    }

    @ViewBuilder
    private func winLine(_ geometry: FourGeometry) -> some View {
        if case .won(_, let line)? = four.outcome, let first = line.first, let last = line.last {
            Path {
                $0.move(to: geometry.center(first))
                $0.addLine(to: geometry.center(last))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: max(3, geometry.cell * 0.1), lineCap: .round))
            .shadow(color: .black.opacity(0.35), radius: 2)
            .allowsHitTesting(false)
        }
    }

    private func columns(_ geometry: FourGeometry) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<FourState.columns, id: \.self) { column in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.sendStageAction(.four(.drop(column: column)), in: conversationID)
                    }
            }
        }
        .frame(width: geometry.grid.width, height: geometry.grid.height)
        .position(x: geometry.grid.midX, y: geometry.grid.midY)
        .disabled(!isMyTurn)
    }

    // MARK: - Beside the board

    /// Who holds a color, and whether it is their go. The empty seat still takes
    /// its width so the board doesn't resize when someone joins.
    private func rail(_ disc: FourDisc) -> some View {
        VStack(spacing: 6) {
            if let player = four.player(disc) {
                UserAvatar(avatar: model.avatar(of: player),
                           size: Self.seatSize,
                           monogram: model.handle(of: player))
            } else {
                openSeat
            }
            Circle()
                .fill(FourPalette.disc(disc))
                .frame(width: 16, height: 16)
        }
        .frame(width: Self.railWidth)
        .opacity(isActive(disc) ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: four.turn)
    }

    private var openSeat: some View {
        Circle()
            .fill(.quaternary)
            .overlay(
                Image(systemName: "questionmark")
                    .font(.system(size: Self.seatSize * 0.45, weight: .semibold))
                    .foregroundStyle(.secondary))
            .frame(width: Self.seatSize, height: Self.seatSize)
    }

    /// Dimming means "not your go", so it applies only to a game in progress.
    private func isActive(_ disc: FourDisc) -> Bool {
        guard four.outcome == nil, four.yellow != nil else { return true }
        return four.turn == disc
    }

    // MARK: - Below the board

    /// On the phone the stage's own red exit already closes a finished game.
    @ViewBuilder
    private var footer: some View {
        #if os(macOS)
        if four.outcome != nil {
            action("Close") { model.closeStage(in: conversationID) }
        }
        #endif
        if four.outcome == nil, four.yellow == nil, four.red != me {
            action("Join") { model.sendStageAction(.four(.join), in: conversationID) }
        }
    }

    private func action(_ label: String, perform: @escaping () -> Void) -> some View {
        Button(label, action: perform)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(height: 22)
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 22)
    }

    // MARK: - The falling piece

    /// The owner sends whole boards, so the move is found by diffing: exactly
    /// one column can have grown.
    private func noteDrop(from old: FourState, to new: FourState) {
        // A fresh game rather than a move.
        guard new.red == old.red, new.yellow == old.yellow else { return }
        guard let column = (0..<FourState.columns).first(where: {
            new.stacks[$0].count == old.stacks[$0].count + 1
        }), let disc = new.stacks[column].last else { return }
        landing = Landing(slot: FourSlot(column: column, row: new.stacks[column].count - 1),
                          disc: disc)
    }

    /// Started from the piece's own `onAppear` so the un-fallen frame has
    /// rendered; from `noteDrop` SwiftUI would coalesce both states into one
    /// frame and the piece would appear where it landed.
    private func drop(_ piece: Landing) {
        // Longer falls take longer, so the board keeps one sense of gravity.
        let distance = Double(FourState.rows - 1 - piece.slot.row)
        let duration = 0.14 + 0.05 * distance
        withAnimation(.easeIn(duration: duration)) { landing?.settled = true }
        Task {
            try? await Task.sleep(for: .seconds(duration))
            // Hand the piece back to the board unless another is already falling.
            if landing?.slot == piece.slot { landing = nil }
        }
    }

    /// Clears the finished board after a pause. Every client runs this and the
    /// version check keeps only the first; it is timed from the owner's stamp so
    /// opening the chat late doesn't restart the countdown.
    private func expireWhenTimeIsUp() async {
        guard let finishedAt = four.finishedAt else { return }
        let remaining = FourState.lingerSeconds - Date().timeIntervalSince(finishedAt)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
        }
        model.sendStageAction(.four(.expire), in: conversationID)
    }
}
