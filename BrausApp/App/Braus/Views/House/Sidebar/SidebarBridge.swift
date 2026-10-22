//
//  SidebarBridge.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// SidebarBridge sets the one thing the team sidebar needs from AppKit that
/// SwiftUI has no modifier for: the split item it is in never collapses.
///
/// It reaches the views SwiftUI built through public API only: up from itself
/// to the enclosing `NSSplitView`, to that view's `NSSplitViewController` and
/// the item whose view holds the bridge, where `canCollapse` becomes false.
/// SwiftUI sets the item back each time it updates the split, so the bridge
/// observes the property and answers every change; a drag of the divider then
/// stops at the column's minimum, and `toggleSidebar:` finds nothing to collapse.
/// It answers on the next turn of the main queue, outside SwiftUI's update.
///
/// The width rule turns the sidebar compact by narrowing its column's range, and widening the
/// range again leaves it at the compact width, which also outlives a relaunch in the split's saved
/// widths. So whenever `isCompact` turns false, the first decision included, a full sidebar
/// narrower than its rows read gets its divider moved back: to the width the sidebar had before
/// it turned compact, or its ideal.
///
/// It depends on SwiftUI hosting the split in an `NSSplitViewController`, as
/// macOS 26 does. Without the split item the shell's guard on the column
/// visibility still reopens a sidebar that went. Outside a split, as in the
/// offscreen snapshot, it changes nothing. The view takes no space and draws
/// nothing.
struct SidebarBridge: NSViewRepresentable {

    /// Whether the window's division keeps the sidebar compact now, nil until it is decided.
    var isCompact: Bool?

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(
        _ view : BridgeView,
        context: Context
    ) {
        view.isCompact = isCompact
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : BridgeView,
        context   : Context
    ) -> CGSize? {
        .zero
    }

    /// The AppKit end: it finds the split item once it is in a window.
    final class BridgeView: NSView {

        private weak var item: NSSplitViewItem?

        private weak var controller: NSSplitViewController?

        private var observation: NSKeyValueObservation?

        /// The width the full sidebar goes back to.
        private var fullWidth = ShellMetrics.sidebar.ideal

        var isCompact: Bool? {
            didSet {
                guard isCompact != oldValue else { return }
                if isCompact == true {
                    // Read before the split applies the compact range, so it is still the full width.
                    if let width = sidebarWidth, width >= ShellMetrics.sidebar.minimum { fullWidth = width }
                } else if isCompact == false {
                    DispatchQueue.main.async { [weak self] in self?.widen() }
                }
            }
        }

        private var isReapplyPending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard window != nil else { return }

            // The split is assembled around this view in the same pass, and completes after it.
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }

        private func connect() {
            guard observation == nil, let item = splitItem() else { return }

            self.item = item
            reapply()
            widen()
            // SwiftUI changes it on the main thread, as AppKit requires of split items.
            observation = item.observe(\.canCollapse) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleReapply() }
            }
        }

        /// Reapplies after the current update, once however many changes arrive within it.
        private func scheduleReapply() {
            guard !isReapplyPending else { return }

            isReapplyPending = true
            DispatchQueue.main.async { [weak self] in
                self?.isReapplyPending = false
                self?.reapply()
            }
        }

        private func reapply() {
            if let item, item.canCollapse { item.canCollapse = false }
        }

        private var sidebarWidth: Double? {
            item.map { Double($0.viewController.view.frame.width) }
        }

        /// Moves the divider so a full sidebar narrower than its rows read is `fullWidth` again.
        private func widen() {
            guard isCompact == false, let controller, let item,
                  let width = sidebarWidth, width < ShellMetrics.sidebar.minimum,
                  let index = controller.splitViewItems.firstIndex(of: item)
            else { return }

            controller.splitView.setPosition(
                fullWidth,
                ofDividerAt: index
            )
        }

        /// The split item holding this view, or nil outside a split.
        private func splitItem() -> NSSplitViewItem? {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) }) {
                    self.controller = controller
                    return item
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}
