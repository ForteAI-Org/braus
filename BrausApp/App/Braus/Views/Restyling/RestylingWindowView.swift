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
/// The window is divided by the team shell's rule (`TeamShellView`, `ShellMetrics.division`): the
/// division is decided from the window's own width, never from a width measured inside the split,
/// the sidebar turns compact before the inspector closes, and a new division gives room first and
/// takes it after. The sidebar is never hidden, and the window's minimum leaves out the inspector's
/// width while it is asked for or shown, as AppKit adds that width itself. The division code mirrors
/// `TeamShellView`'s line for line; share one implementation when the mockup is wired to the team.
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

    /// The window's width as AppKit last reported it, nil before the first report.
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
                min  : ShellMetrics.compactSidebar,
                ideal: division.isSidebarCompact ? ShellMetrics.compactSidebar : ShellMetrics.sidebar.ideal,
                max  : division.isSidebarCompact ? ShellMetrics.compactSidebar : ShellMetrics.sidebar.maximum
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
                    .inspectorColumnWidth(
                        min  : ShellMetrics.inspector.minimum,
                        ideal: ShellMetrics.inspector.ideal,
                        max  : ShellMetrics.inspector.maximum
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
            minWidth : isInspectorInWindow ? ShellMetrics.windowMinimumBesideInspector : ShellMetrics.windowMinimum,
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
                target.isInspectorShown ? "Hide Inspector" : "Show Inspector",
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

    /// Whether the inspector is asked for or still shown, when the window's minimum leaves out its width.
    private var isInspectorInWindow: Bool {
        target.isInspectorShown || division.isInspectorShown
    }

    /// What the inspector shows, and a close from the inspector's own edge.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { division.isInspectorShown },
            set: { isShown in
                guard !isShown else { return }

                isInspectorRequested = false
                divide(into: .withoutInspector)
            }
        )
    }

    /// Closes a shown inspector, or opens it, compacting the sidebar when that is what makes room.
    private func toggleInspector() {
        guard !target.isInspectorShown else {
            isInspectorRequested = false
            divide(into: .withoutInspector)
            return
        }

        isInspectorRequested = true
        guard let windowWidth else { return }

        divide(into: ShellMetrics.division(
            window  : windowWidth,
            previous: nil
        ))
    }

    /// The first report decides once; later ones apply the resize rule with its hysteresis.
    private func windowResized(to width: Double) {
        let isFirst = windowWidth == nil
        guard width != windowWidth else { return }

        windowWidth = width
        guard isInspectorRequested else { return }

        divide(into: ShellMetrics.division(
            window  : width,
            previous: isFirst ? nil : target
        ))
    }

    /// Applies `next` in two steps: at once what gives room, then, after the split has made it,
    /// what takes room. A newer division cancels the second step of an older one.
    private func divide(into next: ShellMetrics.Division) {
        secondStep?.cancel()
        target = next

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
            division = next
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

    /// FirstWindowSize opens the house at the design's 1180 × 720 when no frame of it was saved.
    /// The scene is shared with the team window, so the size is set here rather than with
    /// `.defaultSize`, and the content's ideal size does not size a new window. It draws nothing.
    ///
    /// The window has no autosave name yet when this view joins it and has saved its frame by the
    /// next turn, so whether a frame was saved is read at once, by the house's own key.
    private struct FirstWindowSize: NSViewRepresentable {

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {}

        /// The AppKit end: it sizes its window once, on the turn after it joins it.
        final class BridgeView: NSView {

            private var isSized = false

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard !isSized, window != nil else { return }

                isSized = true
                guard !Self.hasSavedFrame else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let window = self?.window else { return }

                    window.setContentSize(NSSize(
                        width : 1180,
                        height: 720
                    ))
                    window.center()
                }
            }

            /// Whether a house window's frame is in the defaults: its key names this view's type.
            private static var hasSavedFrame: Bool {
                let house = String(describing: RestylingWindowView.self)
                return UserDefaults.standard.dictionaryRepresentation().keys.contains {
                    $0.hasPrefix("NSWindow Frame ") && $0.contains(house)
                }
            }
        }
    }
}
