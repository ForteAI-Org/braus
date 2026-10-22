//
//  HouseSidebar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseSidebar is the house's sidebar: the team's `workers` as rooms or as rows, as Settings
/// chooses, with a search field that finds a worker by name or role (`TeamRow.matches`) and that
/// Edit > Find… (⌘F) focuses, unless Settings leaves it out (`showsSearch`) or the sidebar is compact,
/// which ends the search. The field stays attached and only its accessory is hidden, so the rooms are
/// never rebuilt when it comes and goes.
/// Each room's context menu holds the worker's commands.
///
/// The room column count follows the sidebar width; rows are cards that put the name under the worker when compact.
/// Nothing here changes the width the split gives the sidebar. When it turns compact or wide again,
/// rooms and rows keep their previous width until the new layout is applied, all at once,
/// with `HouseLayout.reshaping`: each one moves and resizes from where it was, its Metal room drawing
/// a live frame at every size on the way. Under Reduce Motion the sidebar cross-fades
/// (`CrossFade`). The foot (`HouseFoot`) floats over the rooms; the archive is in the sidebar's
/// toolbar (`HouseArchiveButton`), left out while searching or empty.
/// The search field draws no focus ring (`SearchFieldWithoutRing`): it keeps the keyboard focus,
/// and the ring would only outline it against the dark sidebar. A room's context menu offers Edit
/// Worker…, which calls `edit`.
struct HouseSidebar: View {
    let workers: [HouseWorker]

    @Binding var selection: HouseWorker.ID?

    let team: TeamModel

    var edit: (HouseWorker.ID) -> Void = { _ in }

    /// Whether the search field is shown, as Settings > Sidebar chooses.
    var showsSearch = AppPreferenceValues.shared.sidebarShowsSearch

    @State private var query = ""

    @State private var columns = 2

    /// The width the rooms and rows are laid out at, which changes with `columns` in one transaction.
    @State private var layoutWidth: CGFloat?

    var body: some View {
        searchField(on: list)
            // Not `.searchFocused`: its focus state re-ran this body on every layout, and the field this body
            // places laid the window out again, without end while workers answered.
            .focusedSceneValue(
                \.findInHouse,
                showsSearchField ? { Self.find(in: NSApp.keyWindow) } : nil
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                resize(to: width)
            }
            // A search the field no longer shows would hide workers with nothing to say why.
            .onChange(of: showsSearchField) {
                if !showsSearchField { query = "" }
            }
    }

    /// The workers as rooms or rows, with the foot and the archive.
    private var list: some View {
        Group {
            switch AppPreferenceValues.shared.houseSidebarMode {
            case .rooms:
                HouseRoomsGrid(
                    workers   : shown,
                    columns   : columns,
                    roomsWidth: roomsWidth,
                    selection : $selection,
                    team      : team,
                    edit      : edit
                )
            case .rows:
                HouseRowsList(
                    workers   : shown,
                    roomsWidth: roomsWidth,
                    isCompact : columns == 1,
                    selection : $selection,
                    team      : team,
                    edit      : edit
                )
            }
        }
        // The foot floats over the rooms, which scroll under it and clear it at the end.
        .safeAreaInset(
            edge   : .bottom,
            spacing: 0
        ) {
            HouseFoot()
        }
        // The archive sits above the rooms in the sidebar's toolbar, beside New Worker.
        .toolbar {
            if archivedCount > 0 {
                ToolbarItem {
                    HouseArchiveButton(
                        archivedCount: archivedCount,
                        team         : team
                    ) { worker in
                        selection = worker
                    }
                }
            }
        }
        .background(CrossFade(columns: columns))
    }

    /// Whether the search field is shown: Settings keeps it and the sidebar is wide enough, which
    /// it is not once its rooms are in one column.
    private var showsSearchField: Bool {
        Self.showsSearchField(
            setting: showsSearch,
            columns: columns
        )
    }

    /// Whether a sidebar of `columns` columns of rooms shows its search field, given Settings' `setting`.
    static func showsSearchField(
        setting: Bool,
        columns: Int
    ) -> Bool {
        setting && columns > 1
    }

    /// `list` under the sidebar's search field, which stays attached so the rooms keep their identity
    /// when the field goes (`SearchFieldWithoutRing.isShown`): Settings or a compact sidebar hides it.
    private func searchField(on list: some View) -> some View {
        list
            .searchable(
                text     : $query,
                placement: .sidebar
            )
            .background(SearchFieldWithoutRing(isShown: showsSearchField))
    }

    /// What Find… (⌘F) does: puts the keyboard in `window`'s sidebar search field, as a click there does.
    static func find(in window: NSWindow?) {
        guard let window, let frame = window.contentView?.superview,
              let field = SearchFieldWithoutRing.BridgeView.searchField(in: frame),
              !field.isHiddenOrHasHiddenAncestor, !field.visibleRect.isEmpty
        else { return }

        window.makeFirstResponder(field)
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
        withAnimation(HouseLayout.reshaping(reducesMotion: HouseMotion.reducesMotion)) {
            columns     = next
            layoutWidth = width
        }
    }

    /// The workers the search finds, all of them while nobody is searching.
    private var shown: [HouseWorker] {
        guard !query.isEmpty else { return workers }

        let words   = query.trimmingCharacters(in: .whitespaces)
        let matches = Set(team.rows.filter { words.isEmpty || $0.matches(words) }.map(\.id))
        return workers.filter { matches.contains($0.id) }
    }

    private var archivedCount: Int {
        query.isEmpty ? team.archived.count : 0
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
            guard view.columns != nil, HouseMotion.reducesMotion, let column = view.column?.layer else { return }

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
    /// focus, and Find… (⌘F) finds it the same way (`find(in:)`). It takes no clicks and draws
    /// nothing. Remove the ring's part when SwiftUI's focus effect reaches the searchable field.
    private struct SearchFieldWithoutRing: NSViewRepresentable {

        /// False hides the sidebar's search field and the room it takes, without removing `.searchable`.
        let isShown: Bool

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {
            view.isFieldShown = isShown
        }

        /// The AppKit end: it finds the field once it is in a window.
        final class BridgeView: NSView {

            var isFieldShown = true {
                didSet {
                    guard isFieldShown != oldValue else { return }
                    showField()
                }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            /// Shows or hides the sidebar's top accessories, which hold the search field alone; before
            /// macOS 26 the field stays.
            private func showField() {
                guard #available(macOS 26, *) else { return }

                var view: NSView? = self
                while let current = view?.superview {
                    if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                       let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) }) {
                        for accessory in item.topAlignedAccessoryViewControllers { accessory.isHidden = !isFieldShown }
                        return
                    }
                    view = current
                }
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard window != nil else { return }
                showField()

                // The searchable field is placed in the same pass as this view, after it.
                DispatchQueue.main.async { [weak self] in
                    self?.showField()
                    guard let frame = self?.window?.contentView?.superview else { return }
                    Self.searchField(in: frame)?.focusRingType = .none
                }
            }

            fileprivate static func searchField(in view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                for subview in view.subviews {
                    if let field = searchField(in: subview) { return field }
                }
                return nil
            }
        }
    }
}
