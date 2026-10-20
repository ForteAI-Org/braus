//
//  HouseSidebar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseSidebar is the mockup's sidebar: the house's workers as rooms or as rows, as Settings
/// chooses, with a search field that finds a worker by name.
///
/// The number of room columns, and whether the rows are compact tiles, follow the width the split
/// gives the sidebar; nothing here changes that width. While searching, the archive is left out.
struct HouseSidebar: View {
    let house: MockHouse

    @Binding var selection: MockWorker.ID?

    @State private var query = ""

    @State private var columns = 2

    var body: some View {
        Group {
            switch AppPreferenceValues.shared.restylingSidebarMode {
            case .rooms:
                HouseRoomsGrid(
                    workers      : workers,
                    archivedCount: archivedCount,
                    columns      : columns,
                    selection    : $selection
                )
            case .rows:
                HouseRowsList(
                    workers      : workers,
                    archivedCount: archivedCount,
                    isCompact    : columns == 1,
                    selection    : $selection
                )
            }
        }
        .searchable(
            text     : $query,
            placement: .sidebar
        )
        .onGeometryChange(for: Int.self) { proxy in
            HouseLayout.columns(sidebarWidth: proxy.size.width)
        } action: { columns in
            self.columns = columns
        }
    }

    private var workers: [MockWorker] {
        guard !query.isEmpty else { return house.workers }
        return house.workers.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var archivedCount: Int {
        query.isEmpty ? house.archivedCount : 0
    }
}
