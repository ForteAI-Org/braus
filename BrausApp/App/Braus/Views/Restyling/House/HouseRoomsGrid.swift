//
//  HouseRoomsGrid.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRoomsGrid is the house as a floor plan: a room per worker in `columns` columns, the first
/// room across both when there are two, and the archive's closed cellar pinned under them.
struct HouseRoomsGrid: View {
    let workers      : [MockWorker]
    let archivedCount: Int
    let columns      : Int

    @Binding var selection: MockWorker.ID?

    var body: some View {
        ScrollView {
            VStack(spacing: HouseLayout.gap) {
                RoomGridLayout(
                    columns: columns,
                    height : isCompact ? HouseLayout.compactRoomHeight : HouseLayout.roomHeight
                ) {
                    ForEach(workers) { worker in
                        room(worker)
                    }
                }
            }
            .padding(
                .horizontal,
                10
            )
        }
        // The archive stays at the foot of the sidebar while the rooms scroll above it.
        .safeAreaInset(edge: .bottom) {
            if archivedCount > 0 {
                cellar
                    .padding(10)
                    .background { Color("RestylingSidebar") }
            }
        }
    }

    private var isCompact: Bool { columns == 1 }

    private func room(_ worker: MockWorker) -> some View {
        HouseRoomCell(
            worker    : worker,
            isSelected: selection == worker.id
        ) {
            selection = worker.id
        }
        .frame(height: isCompact ? HouseLayout.compactRoomHeight : HouseLayout.roomHeight)
    }

    /// The archive, a closed room under the house; in the compact sidebar only its door shows.
    private var cellar: some View {
        HStack(spacing: 8) {
            Image(systemName: "door.left.hand.closed")
            if !isCompact {
                Text("Archive · \(archivedCount)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .frame(
            maxWidth : .infinity,
            minHeight: 40
        )
        .background(
            Color(white: 0.045),
            in: RoundedRectangle(
                cornerRadius: 12,
                style       : .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 12,
                style       : .continuous
            )
            .strokeBorder(.white.opacity(0.04))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Archive, \(archivedCount) workers")
    }
}

/// RoomGridLayout keeps every room in one stable subtree as the sidebar changes columns.
/// The first room spans the width; the remaining rooms fill equal columns at a fixed height.
/// Keeping the small floor plan eager retains each room's last Metal frame through compaction.
nonisolated private struct RoomGridLayout: Layout {
    let columns: Int
    let height : CGFloat

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
            width : proposal.width ?? ShellMetrics.sidebar.ideal - 20,
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
        let width = max(
            0,
            (bounds.width - CGFloat(count - 1) * HouseLayout.gap) / CGFloat(count)
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
                    width : index == 0 ? bounds.width : width,
                    height: height
                )
            )
        }
    }
}
