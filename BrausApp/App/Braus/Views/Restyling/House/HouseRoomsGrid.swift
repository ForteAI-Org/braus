//
//  HouseRoomsGrid.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRoomsGrid is the house as a floor plan: a room per worker in `columns` columns, the first
/// room across both when there are two. The rooms scroll under the sidebar's foot (`HouseFoot`).
///
/// The rooms are laid out `roomsWidth` across, the width `HouseSidebar` changes together with
/// `columns`, so a change of columns moves every room from where it was on screen. They are seen
/// through the camera `BRAUS_ROOM_CAMERA` picks at launch. A room chosen out of sight, as a worker
/// just created is, scrolls into view; each offers Edit Worker… (`edit`) and the worker's commands
/// in its context menu (`HouseWorkerMenu`). The grid is one stop in the Tab order, as the rows list
/// is (`HouseRoomsKeyStop`): the arrow keys move the selection from room to room
/// (`neighbour(of:count:columns:direction:)`), Return hands the keyboard to the composer, and the
/// room the keys would move from wears a ring while the grid holds the keyboard.
struct HouseRoomsGrid: View {
    let workers   : [HouseWorker]
    let columns   : Int
    let roomsWidth: CGFloat?

    @Binding var selection: HouseWorker.ID?

    let team: TeamModel
    let edit: (HouseWorker.ID) -> Void

    @Environment(\.openWorkerScreen) private var openWorkerScreen

    /// Whether the grid holds the keyboard.
    @State private var isFocused = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: HouseLayout.gap) {
                    RoomGridLayout(
                        columns: columns,
                        height : isCompact ? HouseLayout.compactRoomHeight : HouseLayout.roomHeight,
                        width  : roomsWidth
                    ) {
                        ForEach(workers) { worker in
                            room(worker)
                                .id(worker.id)
                                .transition(HouseLayout.arrival)
                        }
                    }
                }
                .padding(
                    .horizontal,
                    HouseLayout.margin
                )
            }
            .background(alignment: .topLeading) {
                HouseRoomsKeyStop(
                    isFocused: $isFocused,
                    move     : move,
                    confirm  : handOver
                )
                .frame(
                    width : 1,
                    height: 1
                )
            }
            .onChange(of: selection) {
                guard let selection else { return }
                // A room just added is laid out after this change, so it is found on the next turn.
                DispatchQueue.main.async { proxy.scrollTo(selection) }
            }
        }
    }

    private var isCompact: Bool { columns == 1 }

    /// Puts the keyboard in the conversation's composer, if a room is chosen.
    private func handOver(from window: NSWindow?) {
        guard selection != nil, let window, let field = Self.composerField(in: window.contentView) else { return }

        window.makeFirstResponder(field)
    }

    private static func composerField(in view: NSView?) -> ComposerTextView? {
        guard let view else { return nil }
        if let field = view as? ComposerTextView { return field }
        for subview in view.subviews {
            if let field = composerField(in: subview) { return field }
        }
        return nil
    }

    /// Selects the room `direction` leads to from the selected one.
    private func move(_ direction: MoveCommandDirection) {
        let index = selection.flatMap { id in workers.firstIndex { $0.id == id } }
        guard let next = Self.neighbour(
            of       : index,
            count    : workers.count,
            columns  : columns,
            direction: direction
        ) else { return }
        selection = workers[next].id
    }

    /// The room an arrow key leads to from the room at `index` on a floor plan of `count` rooms in
    /// `columns` columns, the first room across them all; nil where it leads nowhere. Left and Right
    /// step through the rooms in order, Up and Down a row; with no room chosen, Down and Right start at
    /// the first room and Up and Left at the last.
    static func neighbour(
        of index : Int?,
        count    : Int,
        columns  : Int,
        direction: MoveCommandDirection
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let index else {
            switch direction {
            case .down, .right: return 0
            case .up, .left   : return count - 1
            default           : return nil
            }
        }
        let columns = max(
            1,
            columns
        )
        let next: Int
        switch direction {
        case .left : next = index - 1
        case .right: next = index + 1
        case .up   : next = index <= columns ? 0 : index - columns
        case .down :
            next = index == 0 ? 1 : min(
                index + columns,
                count - 1
            )
        default:
            return nil
        }
        return (0..<count).contains(next) && next != index ? next : nil
    }

    private func room(_ worker: HouseWorker) -> some View {
        HouseRoomCell(
            worker    : worker,
            isSelected: selection == worker.id,
            camera    : RoomCamera.launch
        ) {
            selection = worker.id
        }
        .frame(height: isCompact ? HouseLayout.compactRoomHeight : HouseLayout.roomHeight)
        // The grid is the one stop; a room is reached with the arrow keys.
        .focusable(false)
        .overlay {
            if isFocused && worker.id == (selection ?? workers.first?.id) { focusRing }
        }
        .contextMenu {
            HouseWorkerMenu(
                workerID: worker.id,
                team    : team,
                edit    : edit
            )
            if worker.usesScreen {
                Button("Open Screen") {
                    WorkerScreenWindowController.open(
                        worker: worker,
                        via   : openWorkerScreen
                    )
                }
            }
        }
    }
}

extension HouseRoomsGrid {

    /// The ring around the room the keys move from, on the room's own edge.
    private var focusRing: some View {
        GeometryReader { proxy in
            RoundedRectangle(
                cornerRadius: CGFloat(RoomLightUniforms.Shape(size: proxy.size).cornerRadius),
                style       : .continuous
            )
            .strokeBorder(
                Color.accentColor,
                lineWidth: 3
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// RoomGridLayout keeps every room in one stable subtree as the sidebar changes columns.
/// The first room spans the width; the remaining rooms fill equal columns at a fixed height.
/// Keeping the small floor plan eager retains each room's last Metal frame through compaction.
///
/// The rooms span `width` when it is given, from the leading edge, rather than the width proposed:
/// the proposal follows the split at once, `width` only when the layout changes.
nonisolated private struct RoomGridLayout: Layout {
    let columns: Int
    let height : CGFloat
    let width  : CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache   : inout ()
    ) -> CGSize {
        let count = max(
            1,
            columns
        )
        let rows  = subviews.isEmpty ? 0 : 1 + (subviews.count - 1 + count - 1) / count
        let gaps  = max(
            0,
            rows - 1
        )
        return CGSize(
            width : proposal.width ?? ShellMetrics.sidebar.ideal - 2 * HouseLayout.margin,
            height: CGFloat(rows) * height + CGFloat(gaps) * HouseLayout.gap
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal : ProposedViewSize,
        subviews : Subviews,
        cache    : inout ()
    ) {
        let count = max(
            1,
            columns
        )
        let span  = self.width ?? bounds.width
        let width = max(
            0,
            (span - CGFloat(count - 1) * HouseLayout.gap) / CGFloat(count)
        )
        for (index, subview) in subviews.enumerated() {
            let row    = index == 0 ? 0 : 1 + (index - 1) / count
            let column = index == 0 ? 0 : (index - 1) % count
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (width + HouseLayout.gap),
                    y: bounds.minY + CGFloat(row) * (height + HouseLayout.gap)
                ),
                anchor  : .topLeading,
                proposal: ProposedViewSize(
                    width : index == 0 ? span : width,
                    height: height
                )
            )
        }
    }
}
