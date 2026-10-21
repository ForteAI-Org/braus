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
/// just created is, scrolls into view; each offers Edit Worker… (`edit`) in its context menu.
struct HouseRoomsGrid: View {
    let workers   : [MockWorker]
    let columns   : Int
    let roomsWidth: CGFloat?

    @Binding var selection: MockWorker.ID?

    let edit: (MockWorker.ID) -> Void

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
            .onChange(of: selection) {
                guard let selection else { return }
                // A room just added is laid out after this change, so it is found on the next turn.
                DispatchQueue.main.async { proxy.scrollTo(selection) }
            }
        }
    }

    private var isCompact: Bool { columns == 1 }

    private func room(_ worker: MockWorker) -> some View {
        HouseRoomCell(
            worker    : worker,
            isSelected: selection == worker.id,
            camera    : RoomCamera.launch
        ) {
            selection = worker.id
        }
        .frame(height: isCompact ? HouseLayout.compactRoomHeight : HouseLayout.roomHeight)
        .contextMenu {
            Button("Edit Worker…") { edit(worker.id) }
        }
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
