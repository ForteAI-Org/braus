//
//  HouseRoomsGrid.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRoomsGrid is the house as a floor plan: a room per worker in `columns` columns, the first
/// room across both when there are two, and the archive's closed cellar last.
struct HouseRoomsGrid: View {
    let workers      : [MockWorker]
    let archivedCount: Int
    let columns      : Int

    @Binding var selection: MockWorker.ID?

    var body: some View {
        ScrollView {
            VStack(spacing: HouseLayout.gap) {
                // LazyVGrid has no spanning cell, so the wide first room sits above it.
                if columns > 1, let first = workers.first {
                    room(first)
                }
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .flexible(),
                            spacing: HouseLayout.gap
                        ),
                        count: columns
                    ),
                    spacing: HouseLayout.gap
                ) {
                    ForEach(columns > 1 ? Array(workers.dropFirst()) : workers) { worker in
                        room(worker)
                    }
                }
                if archivedCount > 0 {
                    cellar
                }
            }
            .padding(
                .horizontal,
                10
            )
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
