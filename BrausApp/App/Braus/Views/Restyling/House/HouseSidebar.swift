//
//  HouseSidebar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseSidebar is the mockup's sidebar: the house's workers as rooms or as rows, as Settings
/// chooses, with a search field that finds a worker by name and that Edit > Find… (⌘F) focuses.
///
/// The number of room columns, and whether the rows are compact tiles, follow the width the split
/// gives the sidebar; nothing here changes that width. While searching, the archive is left out.
/// The search field draws no focus ring (`SearchFieldWithoutRing`): it keeps the keyboard focus,
/// and the ring would only outline it against the dark sidebar.
struct HouseSidebar: View {
    let house: MockHouse

    @Binding var selection: MockWorker.ID?

    @State private var query = ""

    @State private var columns = 2

    @FocusState private var isSearchFocused: Bool

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
        .searchFocused($isSearchFocused)
        .background(SearchFieldWithoutRing())
        .focusedSceneValue(
            \.findInHouse,
            { isSearchFocused = true }
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

    /// SearchFieldWithoutRing turns off the focus ring of the sidebar's search field, which SwiftUI
    /// draws as an `NSSearchField` with no modifier for its ring; `.focusEffectDisabled()` leaves it.
    ///
    /// Once in a window, on the next turn, it walks up to the window's frame view and down to the one
    /// search field there, the sidebar's, and sets its `focusRingType`. The field keeps the keyboard
    /// focus and ⌘F. It takes no clicks and draws nothing. Remove it when SwiftUI's focus effect
    /// reaches the searchable field.
    private struct SearchFieldWithoutRing: NSViewRepresentable {

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {}

        /// The AppKit end: it finds the field once it is in a window.
        final class BridgeView: NSView {

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard window != nil else { return }

                // The searchable field is placed in the same pass as this view, after it.
                DispatchQueue.main.async { [weak self] in
                    guard let frame = self?.window?.contentView?.superview else { return }
                    Self.searchField(in: frame)?.focusRingType = .none
                }
            }

            private static func searchField(in view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                for subview in view.subviews {
                    if let field = searchField(in: subview) { return field }
                }
                return nil
            }
        }
    }
}
