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
/// The room column count follows the sidebar width; rows keep their compact cards at every width.
/// Nothing here changes the width the split gives the sidebar. When it turns compact or wide again,
/// rooms and rows keep their previous width until the new layout is applied, all at once,
/// with `HouseLayout.reshaping`: each one moves and resizes from where it was, its Metal room drawing
/// a live frame at every size on the way. Under Reduce Motion the sidebar cross-fades
/// (`CrossFade`). The foot (`HouseFoot`) floats over the rooms with the account; the archive is in
/// the sidebar's toolbar (`HouseArchiveButton`), left out while searching or empty.
/// The search field draws no focus ring (`SearchFieldWithoutRing`): it keeps the keyboard focus,
/// and the ring would only outline it against the dark sidebar. A room's context menu offers Edit
/// Worker…, which calls `edit`.
struct HouseSidebar: View {
    let house: MockHouse

    @Binding var selection: MockWorker.ID?

    var edit: (MockWorker.ID) -> Void = { _ in }

    @State private var query = ""

    @State private var columns = 2

    /// The width the rooms and rows are laid out at, which changes with `columns` in one transaction.
    @State private var layoutWidth: CGFloat?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            switch AppPreferenceValues.shared.restylingSidebarMode {
            case .rooms:
                HouseRoomsGrid(
                    workers   : workers,
                    columns   : columns,
                    roomsWidth: roomsWidth,
                    selection : $selection,
                    edit      : edit
                )
            case .rows:
                HouseRowsList(
                    workers   : workers,
                    roomsWidth: roomsWidth,
                    selection : $selection,
                    edit      : edit
                )
            }
        }
        // The foot floats over the rooms, which scroll under it and clear it at the end.
        .safeAreaInset(
            edge   : .bottom,
            spacing: 0
        ) {
            HouseFoot(account: .sample)
        }
        // The archive sits above the rooms in the sidebar's toolbar, beside New Worker.
        .toolbar {
            if archivedCount > 0 {
                ToolbarItem {
                    HouseArchiveButton(archivedCount: archivedCount)
                }
            }
        }
        .background(CrossFade(columns: columns))
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            resize(to: width)
        }
    }

    /// The rooms' width inside the sidebar's margins, nil until the sidebar is measured.
    private var roomsWidth: CGFloat? {
        layoutWidth.map { max(0, $0 - 2 * HouseLayout.margin) }
    }

    /// Follows the sidebar's width at once, and reshapes the rooms when it changes their columns.
    private func resize(to width: CGFloat) {
        let next = HouseLayout.columns(sidebarWidth: width)
        guard next != columns, layoutWidth != nil else {
            columns     = next
            layoutWidth = width
            return
        }
        withAnimation(HouseLayout.reshaping(reducesMotion: RestylingMotion.reducesMotion)) {
            columns     = next
            layoutWidth = width
        }
    }

    private var workers: [MockWorker] {
        guard !query.isEmpty else { return house.workers }
        return house.workers.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var archivedCount: Int {
        query.isEmpty ? house.archivedCount : 0
    }

    /// CrossFade cross-fades the sidebar column when the number of room columns changes under Reduce
    /// Motion, in place of the rooms' movement.
    ///
    /// SwiftUI updates it in the same pass that lays out the new columns, so the Core Animation fade it
    /// adds to the column's view runs from the old layout on screen to the new one. It finds that view
    /// up from itself: the split view's subview that holds it. It takes no clicks and draws nothing.
    private struct CrossFade: NSViewRepresentable {
        let columns: Int

        private static let seconds = 0.2

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {
            guard columns != view.columns else { return }
            defer { view.columns = columns }
            guard view.columns != nil, RestylingMotion.reducesMotion, let column = view.column?.layer else { return }

            let fade = CATransition()
            fade.type     = .fade
            fade.duration = Self.seconds
            column.add(
                fade,
                forKey: kCATransition
            )
        }

        /// The AppKit end: it remembers the columns it last saw and finds the sidebar's column.
        final class BridgeView: NSView {

            var columns: Int?

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            var column: NSView? {
                var view: NSView? = self
                while let current = view, let parent = current.superview {
                    if parent is NSSplitView { return current }
                    view = parent
                }
                return nil
            }
        }
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
