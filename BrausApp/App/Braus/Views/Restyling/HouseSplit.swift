//
//  HouseSplit.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseSplit is the house window's frame, dark only: a sidebar, the conversation beside it and an
/// inspector the person asks for, on the house's own grounds.
///
/// The callers bring the columns' content, their toolbar items and what a selection does; the split
/// owns how the window is divided. The window has no title and a transparent title bar, and the
/// toolbar no background of its own, so the dark ground runs up under it: without the transparent
/// title bar, AppKit draws its grey behind the conversation's toolbar once the transcript's scroll
/// view is in the column.
///
/// RestylingWindowLayout budgets for the columns' ideal widths, including without an inspector: the
/// division is decided from the window's own width, never from a width measured inside the split,
/// the sidebar turns compact before the inspector closes, and a new division gives room first and
/// takes it after. The sidebar is never hidden: it has no toggle and no command, and `SidebarBridge`
/// stops a drag of its divider at the compact width instead of collapsing it, so nothing has to
/// reopen it. The root minimum always leaves out the inspector's width, which AppKit adds itself,
/// so automatically closing it cannot raise the root minimum. Only the person changes
/// `isInspectorRequested`; the split follows each change of it and reports what the window shows
/// in `isInspectorShown`, which a toolbar button names itself by.
///
/// The window, sidebar and inspector backgrounds are the asset catalogue's `RestylingGround`,
/// `RestylingSidebar` and `RestylingInspector`, darker than the system's greys.
struct HouseSplit<Sidebar: View, Detail: View, Inspector: View>: View {

    /// Whether the person asked for the inspector, which a narrow window may not show yet.
    @Binding var isInspectorRequested: Bool

    /// Whether the window shows the inspector now, written by the split as its division changes.
    @Binding var isInspectorShown: Bool

    @ViewBuilder var sidebar: Sidebar

    @ViewBuilder var detail: Detail

    @ViewBuilder var inspector: Inspector

    /// The last reported width, used only by resize and toggle actions, never by column modifiers.
    @State private var windowWidth: Double?

    /// What the window shows now, which lags `target` while a division is applied in two steps.
    @State private var division = ShellMetrics.Division.withoutInspector

    /// What the rule last decided, which a resize compares against.
    @State private var target = ShellMetrics.Division.withoutInspector

    /// The second step of the division being applied, cancelled by a newer one.
    @State private var secondStep: Task<Void, Never>?

    /// Longer than AppKit takes to close the inspector column: 250 ms, measured on macOS 26.
    private static var inspectorClosing: Duration { .milliseconds(300) }

    /// Long enough for the split to lay out the compact sidebar before the inspector opens beside it.
    private static var sidebarCompacting: Duration { .milliseconds(50) }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(RestylingWindowLayout.columnVisibility)) {
            sidebar
                .background(SidebarBridge(isCompact: windowWidth.map { _ in division.isSidebarCompact }))
                // The system's sidebar material reads grey; the house's sidebar is darker, from the asset catalogue.
                .scrollContentBackground(.hidden)
                .background { Color("RestylingSidebar").ignoresSafeArea() }
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(
                    min  : sidebarWidth.minimum,
                    ideal: sidebarWidth.ideal,
                    max  : sidebarWidth.maximum
                )
        } detail: {
            detail
                .frame(
                    minWidth : 0,
                    maxWidth : .infinity,
                    minHeight: 0,
                    maxHeight: .infinity
                )
                .background { Color("RestylingGround").ignoresSafeArea() }
                .inspector(isPresented: inspectorPresentation) {
                    inspector
                        .scrollContentBackground(.hidden)
                        .frame(
                            maxWidth : .infinity,
                            maxHeight: .infinity
                        )
                        .background { Color("RestylingInspector").ignoresSafeArea() }
                        // The system's separator between the conversation and the inspector.
                        .overlay(alignment: .leading) {
                            HStack(spacing: 0) { Divider() }
                                .ignoresSafeArea()
                        }
                        .inspectorColumnWidth(
                            min  : RestylingWindowLayout.inspectorWidth.minimum,
                            ideal: RestylingWindowLayout.inspectorWidth.ideal,
                            max  : RestylingWindowLayout.inspectorWidth.maximum
                        )
                }
        }
        .toolbar(removing: .title)
        // The toolbar's own grey would band the dark ground; the ground runs up under it instead.
        .toolbarBackgroundVisibility(
            .hidden,
            for: .windowToolbar
        )
        .frame(
            minWidth : RestylingWindowLayout.minimumWidth,
            minHeight: 560
        )
        .background(WindowWidthReader(onWidth: windowResized))
        .background(TransparentTitleBar())
        .onChange(of: isInspectorRequested) { inspectorRequestChanged() }
        .onChange(
            of     : division.isInspectorShown,
            initial: true
        ) {
            isInspectorShown = division.isInspectorShown
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Division

    private var sidebarWidth: ColumnWidth {
        RestylingWindowLayout.sidebarWidth(for: division)
    }

    /// Presents the width rule's result. SwiftUI also writes back an automatic dismissal after its
    /// animation, possibly after a newer division, so writebacks cannot change the person's request.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { division.isInspectorShown },
            set: { _ in }
        )
    }

    /// Divides for the person's new request, including cancelling one temporarily hidden by a narrow window.
    private func inspectorRequestChanged() {
        guard let windowWidth else { return }

        divide(into: RestylingWindowLayout.division(
            window              : windowWidth,
            isInspectorRequested: isInspectorRequested,
            previous            : nil
        ))
    }

    /// The first report decides once; later ones apply the resize rule with its hysteresis.
    private func windowResized(to width: Double) {
        let isFirst = windowWidth == nil
        guard width != windowWidth else { return }

        windowWidth = width
        divide(into: RestylingWindowLayout.division(
            window              : width,
            isInspectorRequested: isInspectorRequested,
            previous            : isFirst ? nil : target
        ))
    }

    /// Applies `next` in two steps: at once what gives room, then, after the split has made it,
    /// what takes room. Only a different target cancels the second step, so live resize cannot
    /// postpone it indefinitely. Sidebar-only changes need no inspector animation wait.
    private func divide(into next: ShellMetrics.Division) {
        guard next != target else { return }
        secondStep?.cancel()
        secondStep = nil
        target = next

        if !division.isInspectorShown, !next.isInspectorShown {
            division = next
            return
        }

        let first = ShellMetrics.Division(
            isInspectorShown: division.isInspectorShown && next.isInspectorShown,
            isSidebarCompact: division.isSidebarCompact || next.isSidebarCompact
        )
        let wait  = division.isInspectorShown && !first.isInspectorShown ? Self.inspectorClosing
                                                                         : Self.sidebarCompacting
        division = first
        guard first != next else { return }

        secondStep = Task {
            // A cancelled wait belongs to a division that a newer one replaced.
            do { try await Task.sleep(for: wait) } catch { return }
            guard !Task.isCancelled, target == next else { return }
            division = next
            secondStep = nil
        }
    }
}
