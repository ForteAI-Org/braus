//
//  HouseRowsList.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRowsList presents compact worker rows with their room lighting and native list selection.
/// Names stay beside the workers at every sidebar width. A newly selected worker scrolls into view,
/// and each row offers Edit Worker… in its context menu.
struct HouseRowsList: View {
    let workers   : [MockWorker]
    let roomsWidth: CGFloat?

    @Binding var selection: MockWorker.ID?

    let edit: (MockWorker.ID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: selection) {
                    guard let selection else { return }
                    // A row just added is laid out after this change, so it is found on the next turn.
                    DispatchQueue.main.async { proxy.scrollTo(selection) }
                }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(workers) { worker in
                HouseWorkerRow(
                    worker    : worker,
                    isSelected: selection == worker.id
                )
                .frame(
                    width : roomsWidth,
                    height: HouseLayout.rowHeight
                )
                .background(QuietSelection())
                .tag(Optional(worker.id))
                .listRowInsets(EdgeInsets(
                    top     : 2,
                    leading : HouseLayout.margin,
                    bottom  : 2,
                    trailing: HouseLayout.margin
                ))
                .listRowSeparator(.hidden)
                .transition(HouseLayout.arrival)
                .contextMenu {
                    Button("Edit Worker…") { edit(worker.id) }
                }
            }
        }
        .listStyle(.plain)
    }

    /// QuietSelection turns off the table's own selection fill under the list, so the row's neutral
    /// background marks the selection; the table still selects by click and by keys. It also
    /// removes the table's spacing between cells, which would push every room 8 points right of the
    /// sidebar's margin.
    ///
    /// Each row carries one. It reaches the table SwiftUI built through public API only: up from
    /// itself to the first enclosing `NSTableView`, which is this list's and never another's. It sets
    /// the style once the row is in a window and observes it, answering every change on the next
    /// turn of the main queue, outside SwiftUI's update. Were the list ever not backed by a table, it
    /// would change nothing and the accent fill would come back. It takes no clicks and draws nothing.
    ///
    /// Remove it when SwiftUI honours `.tint` for a list's selection or offers a modifier for its
    /// selection style, and the list's rows reach its edges.
    private struct QuietSelection: NSViewRepresentable {

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {}

        /// The AppKit end: it finds its table once it is in a window.
        final class BridgeView: NSView {

            private weak var table: NSTableView?

            private var observation: NSKeyValueObservation?

            private var isQuietPending = false

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                observation = nil
                guard window != nil else { return }

                // The row is placed in its table in the same pass, and completes after it.
                DispatchQueue.main.async { [weak self] in self?.connect() }
            }

            private func connect() {
                guard observation == nil, let table = enclosingTable() else { return }

                self.table = table
                quiet()
                observation = table.observe(\.selectionHighlightStyle) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleQuiet() }
                }
            }

            /// Quiets the table after the current update, once however many changes arrive within it.
            private func scheduleQuiet() {
                guard !isQuietPending else { return }

                isQuietPending = true
                DispatchQueue.main.async { [weak self] in
                    self?.isQuietPending = false
                    self?.quiet()
                }
            }

            private func quiet() {
                guard let table else { return }
                if table.intercellSpacing.width != 0 {
                    table.intercellSpacing = NSSize(
                        width : 0,
                        height: table.intercellSpacing.height
                    )
                }
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
            }

            private func enclosingTable() -> NSTableView? {
                var ancestor = superview
                while let view = ancestor {
                    if let table = view as? NSTableView { return table }
                    ancestor = view.superview
                }
                return nil
            }
        }
    }
}
