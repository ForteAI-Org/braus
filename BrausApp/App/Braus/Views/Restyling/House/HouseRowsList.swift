//
//  HouseRowsList.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRowsList is the house as the system's sidebar list: a row per worker, and the archive pinned
/// under the list, outside it, so it cannot be selected.
///
/// The list keeps the system's selection, by click and by keys, but not its fill: the accent fill
/// reads as a status light (an orange accent as busy, the blue one as waiting) and drowns the halo,
/// so `QuietSelection` turns the table's fill off and the selected row gets a neutral one instead.
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
                .background(QuietSelection())
                .tag(Optional(worker.id))
                .listRowBackground(selection == worker.id ? selectedBackground : nil)
            }
        }
        .listStyle(.sidebar)
        // The archive stays at the foot of the sidebar while the rows scroll above it.
        .safeAreaInset(edge: .bottom) {
            if archivedCount > 0 {
                archive
                    .padding(
                        .horizontal,
                        20
                    )
                    .padding(
                        .vertical,
                        6
                    )
                    .background { Color("RestylingSidebar") }
            }
        }
    }

    /// The selected row's quiet fill, as the prototype's: white at 9% with a faint inner edge, inset
    /// as the system's own selection.
    private var selectedBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: 12,
            style       : .continuous
        )
        return shape
            .fill(.white.opacity(0.09))
            .overlay {
                shape.strokeBorder(.white.opacity(0.08))
            }
            .padding(
                .horizontal,
                10
            )
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Archive, \(archivedCount) workers")
    }

    /// QuietSelection turns off the table's own selection fill under the list, so the neutral row
    /// background is the only mark of the selection; the table still selects by click and by keys.
    ///
    /// Each row carries one. It reaches the table SwiftUI built through public API only: up from
    /// itself to the first enclosing `NSTableView`, which is this list's and never another's. It sets
    /// the style once the row is in a window and observes it, answering every change on the next
    /// turn of the main queue, outside SwiftUI's update. Were the list ever not backed by a table, it
    /// would change nothing and the accent fill would come back. It takes no clicks and draws nothing.
    ///
    /// Remove it, with the neutral row background, when SwiftUI honours `.tint` for a sidebar list's
    /// selection or offers a modifier for its selection style.
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
                guard let table, table.selectionHighlightStyle != .none else { return }
                table.selectionHighlightStyle = .none
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
