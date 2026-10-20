//
//  HouseRowsList.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRowsList is the house as the system's sidebar list: a row per worker and the archive as the
/// last row, which cannot be selected.
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
                .tag(Optional(worker.id))
                .listRowBackground(selection == worker.id ? selectedBackground : nil)
            }
            if archivedCount > 0 {
                archive
            }
        }
        .listStyle(.sidebar)
        .background(QuietSelection())
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
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Archive, \(archivedCount) workers")
    }

    /// QuietSelection turns off the table's own selection fill under the list, so the neutral row
    /// background is the only mark of the selection; the table still selects by click and by keys.
    ///
    /// It reaches the table SwiftUI built through public API only: the nearest `NSTableView` around
    /// itself, after each update, since SwiftUI may set the style again. Were the list ever not
    /// backed by a table, it would change nothing and the accent fill would come back.
    private struct QuietSelection: NSViewRepresentable {

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {
            view.scheduleQuiet()
        }

        final class BridgeView: NSView {

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                scheduleQuiet()
            }

            /// Quiets the table after the current update, once SwiftUI has built or changed it.
            func scheduleQuiet() {
                DispatchQueue.main.async { [weak self] in self?.quiet() }
            }

            private func quiet() {
                var ancestor = superview
                while let view = ancestor {
                    if let table = Self.table(in: view) {
                        if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                        return
                    }
                    ancestor = view.superview
                }
            }

            private static func table(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                for subview in view.subviews {
                    if let table = table(in: subview) { return table }
                }
                return nil
            }
        }
    }
}
