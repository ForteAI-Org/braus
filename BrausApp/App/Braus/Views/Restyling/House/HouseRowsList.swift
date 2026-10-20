//
//  HouseRowsList.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRowsList is the house as the system's sidebar list: a row per worker, highlighted when
/// selected, and the archive as the last row, which cannot be selected.
struct HouseRowsList: View {
    let workers      : [MockWorker]
    let archivedCount: Int
    let isCompact    : Bool

    @Binding var selection: MockWorker.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(workers) { worker in
                HouseRowCell(
                    worker   : worker,
                    isCompact: isCompact
                )
                .tag(Optional(worker.id))
            }
            if archivedCount > 0 {
                archive
            }
        }
        .listStyle(.sidebar)
    }

    private var archive: some View {
        HStack(spacing: 9) {
            Image(systemName: "door.left.hand.closed")
            if !isCompact {
                Text("Archive · \(archivedCount)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .frame(
            maxWidth : .infinity,
            minHeight: 36,
            alignment: isCompact ? .center : .leading
        )
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Archive, \(archivedCount) workers")
    }
}
