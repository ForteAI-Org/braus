//
//  RestylingWindowView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// RestylingWindowView is the restyling mockup's house window, dark only: the house in the sidebar,
/// the conversation with the chosen worker, and an inspector that opens from the toolbar.
///
/// The toolbar holds New Worker beside the traffic lights, and at the trailing edge the Screen and
/// Inspector controls; the window has no title, as the worker sits at the top of its conversation.
/// New Worker is a placeholder. Edit > Find… focuses the sidebar's search (`HouseFindCommands`).
///
/// A worker chosen with the pointer hands the keyboard to the composer, so the sidebar's selection
/// draws unemphasized; one chosen with the arrow keys leaves it in the sidebar to keep browsing, and
/// Return there moves it to the composer.
///
/// RestylingWindowLayout budgets for the columns' ideal widths, including without an inspector: the
/// division is decided from the window's own width, never from a width measured inside the split,
/// the sidebar turns compact before the inspector closes, and a new division gives room first and
/// takes it after. The sidebar is never hidden. The root minimum always leaves out the inspector's
/// width, which AppKit adds itself, so automatically closing it cannot raise the root minimum.
/// Only the toolbar action or its shortcut changes the person's inspector request.
///
/// The window, sidebar and inspector backgrounds are the asset catalogue's `RestylingGround`,
/// `RestylingSidebar` and `RestylingInspector`, darker than the system's greys.
struct RestylingWindowView: View {

    /// Longer than AppKit takes to close the inspector column, as in `TeamShellView`.
    private static let inspectorClosing = Duration.milliseconds(300)

    /// Long enough for the split to lay out the compact sidebar before the inspector opens beside it.
    private static let sidebarCompacting = Duration.milliseconds(50)

    @State private var house = MockHouse.sample

    @State private var selection: MockWorker.ID?

    /// Whether the person asked for the inspector, which a narrow window may not show yet.
    @State private var isInspectorRequested = false

    /// The last reported width, used only by resize and toggle actions, never by column modifiers.
    @State private var windowWidth: Double?

    /// What the window shows now, which lags `target` while a division is applied in two steps.
    @State private var division = ShellMetrics.Division.withoutInspector

    /// What the rule last decided, which a resize compares against.
    @State private var target = ShellMetrics.Division.withoutInspector

    /// The second step of the division being applied, cancelled by a newer one.
    @State private var secondStep: Task<Void, Never>?

    @State private var showsScreen = true

    /// Always `.all`: the guard below puts back anything else.
    @State private var columns = NavigationSplitViewVisibility.all

    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            HouseSidebar(
                house    : house,
                selection: $selection
            )
            // The system's sidebar material reads grey; the house's sidebar is darker, from the asset catalogue.
            .scrollContentBackground(.hidden)
            .background { Color("RestylingSidebar").ignoresSafeArea() }
            .onKeyPress(.return) {
                guard selection != nil else { return .ignored }
                isComposerFocused = true
                return .handled
            }
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem {
                    Button(
                        "New Worker",
                        systemImage: "plus"
                    ) {}
                    .help("New worker")
                }
            }
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
                .toolbar { toolbar }
                .inspector(isPresented: inspectorPresentation) {
                    HouseInspector(
                        worker     : selectedWorker,
                        showsScreen: showsScreen
                    )
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
        .background(FirstWindowSize())
        .frame(
            minWidth : RestylingWindowLayout.minimumWidth,
            minHeight: 560
        )
        .background(WindowWidthReader(onWidth: windowResized))
        .onChange(of: columns) {
            if columns != .all { columns = .all }
        }
        .onChange(of: selection) {
            guard selection != nil, NSApp.currentEvent?.type != .keyDown else { return }
            Task {
                // Asked for before the new composer is in its window, the focus would be dropped.
                await Task.yield()
                isComposerFocused = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private var selectedWorker: MockWorker? {
        house.workers.first { $0.id == selection }
    }

    // MARK: Toolbar

    /// The Screen and Inspector controls at the trailing edge. The window has no title, so the
    /// flexible space takes them there; before macOS 26 it is an item holding only a spacer.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem { Spacer() }
        }

        ToolbarItem {
            Toggle(isOn: $showsScreen) {
                Label(
                    "Show Screen",
                    systemImage: "display"
                )
            }
            .toggleStyle(.button)
            .disabled(selectedWorker?.status != .busy)
            .help("Show or hide the worker’s screen.")
        }

        ToolbarItem {
            Button(
                isInspectorRequested ? "Hide Inspector" : "Show Inspector",
                systemImage: "info.circle",
                action     : toggleInspector
            )
            .keyboardShortcut(
                "i",
                modifiers: [.control, .option, .command]
            )
            .help("Show or hide the inspector.")
        }
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

    /// Toggles the person's request, including cancelling one temporarily hidden by a narrow window.
    private func toggleInspector() {
        isInspectorRequested.toggle()
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

    // MARK: Areas

    @ViewBuilder
    private var detail: some View {
        if let worker = selectedWorker {
            HouseConversationView(
                worker           : worker,
                isComposerFocused: $isComposerFocused
            )
            .id(worker.id)
        } else {
            ContentUnavailableView(
                "Choose a Room",
                systemImage: "house",
                description: Text("Pick a room to talk with its worker.")
            )
        }
    }

    /// FirstWindowSize opens the house at the design's 1180 × 720 the first time, then never again,
    /// so later launches keep the frame the person left. The scene is shared with the team window,
    /// whose saved frame the house inherits, so the first time is the house's own defaults flag
    /// (`AppPreferences.restylingDidSizeWindow`), not a saved frame. It draws nothing.
    private struct FirstWindowSize: NSViewRepresentable {

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {}

        /// The AppKit end: it sizes its window once, on the turn after it joins it.
        final class BridgeView: NSView {

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                let defaults = UserDefaults.standard
                guard window != nil, !defaults.bool(forKey: AppPreferences.restylingDidSizeWindow) else { return }

                defaults.set(
                    true,
                    forKey: AppPreferences.restylingDidSizeWindow
                )
                // After SwiftUI has restored the scene's saved frame, which would otherwise win.
                DispatchQueue.main.async { [weak self] in
                    guard let window = self?.window else { return }

                    window.setContentSize(NSSize(
                        width : 1180,
                        height: 720
                    ))
                    window.center()
                }
            }
        }
    }
}
