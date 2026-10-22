//
//  WindowClickCheck.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// WindowClickCheck puts the house window (`HouseShellView`) in a real key
/// window, when the app is launched with BRAUS_CLICK_CHECK=1, and drives it
/// with events sent through the window: the inspector's shortcut both ways,
/// Shift-Tab into the house's sidebar, a click on a room, which hands
/// the keyboard to the composer, a narrower window with the inspector open,
/// where the sidebar must turn compact, and back, Edit Worker…, which puts the
/// keyboard in the inspector's Name field, and every way a sidebar is
/// hidden (the View menu, Control-Command-S, `toggleSidebar:` and a drag of the
/// divider to the window's edge), none of which may hide it. It prints what
/// each step found and quits with 0 when every step held, 1 otherwise.
///
/// SwiftUI builds no accessibility tree without an assistive client, so the
/// targets are found by their views: a room by its light (`RoomLightView`), the
/// divider at the sidebar pane's trailing edge. The events go to the window, so
/// the pointer never moves. The team is `WindowSnapshots`'s synthetic one, in a
/// temporary store.
@MainActor
enum WindowClickCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["BRAUS_CLICK_CHECK"] == "1" }

    private struct CheckFailure: Error, CustomStringConvertible {

        let description: String
    }

    static func runAndQuit() async {
        let store = URL.temporaryDirectory.appending(
            path         : "BrausClickCheck-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var status: Int32 = 0

        do {
            try await run(team: WindowSnapshots.syntheticTeam(in: store))
            print("click check: every step held")
        } catch {
            FileHandle.standardError.write(Data("click check failed: \(error)\n".utf8))
            status = 1
        }

        // A leftover temporary store is reclaimed by the system; it must not change the exit status.
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(status)
    }

    private static func run(team: TeamModel) async throws {
        let probe   = Probe()
        let hosting = NSHostingView(rootView: ProbedRoot(
            team : team,
            probe: probe
        ))
        hosting.sizingOptions        = [.minSize]
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(
                x     : 120,
                y     : 120,
                width : 1200,
                height: 720
            ),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView          = hosting
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(3))
        if !window.isKeyWindow {
            // Launched from a shell, the app may not be allowed to take the front on its own.
            NSRunningApplication.current.activate(options: .activateAllWindows)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(2))
        }
        print("click check: app active \(NSApp.isActive), key \(window.isKeyWindow), frame \(window.frame)")

        print("click check: window title \"\(window.title)\", title visibility \(window.titleVisibility.rawValue)")
        let items = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        print("click check: toolbar items \(items)")

        let panes      = try splitPanes(in: hosting)
        let paneFrames = panes.map {
            window.contentView?.convert(
                $0.bounds,
                from: $0
            ) ?? .zero
        }
        print("click check: panes \(paneFrames)")
        try expect(
            !probe.isInspectorRequested && !showsInspector(hosting),
            "the inspector is shown before the shortcut"
        )

        // The inspector's own shortcut opens it and closes it again, and the
        // sidebar, which the window is wide enough to keep full, stays shown and as wide throughout.
        printSplitItems(in: hosting)
        let width = try sidebarWidth(in: hosting)
        for shows in [true, false] {
            press(
                "i",
                keyCode   : 34,
                modifiers : [.control, .option, .command],
                in        : window,
                throughApp: true
            )
            let narrowest = try await narrowestSidebar(
                in : hosting,
                for: .seconds(1)
            )
            print("click check: after Control-Option-Command-I, requested \(probe.isInspectorRequested), "
                + "sidebar narrowest \(narrowest)")
            printSplitItems(in: hosting)
            try expect(
                probe.isInspectorRequested == shows && showsInspector(hosting) == shows,
                "Control-Option-Command-I did not \(shows ? "show" : "hide") the inspector"
            )
            try expect(
                narrowest == width,
                "\(shows ? "showing" : "hiding") the inspector changed the sidebar from \(width) to \(narrowest)"
            )
        }

        try await checkKeyboardSelection(
            team   : team,
            hosting: hosting,
            window : window
        )
        // Compaction first: after the person drags the divider, the split keeps their width over `ideal`.
        try await checkCompaction(
            probe  : probe,
            hosting: hosting,
            window : window
        )
        try await checkEditWorker(
            team   : team,
            probe  : probe,
            hosting: hosting,
            window : window
        )
        try await checkTheSidebarStays(
            hosting: hosting,
            window : window
        )
        window.close()
    }

    // MARK: Steps

    /// The house is in the key loop before the conversation, in the order rooms,
    /// search field, conversation, composer: Tab from nothing focused reaches the
    /// conversation, Shift-Tab from there the search field and the rooms, and Tab
    /// from the rooms the search field again. With the rooms holding the
    /// keyboard, Down and Up move the selection and Return hands the keyboard to
    /// the composer. A click on the second room then selects it and hands the
    /// keyboard to the composer.
    private static func checkKeyboardSelection(
        team   : TeamModel,
        hosting: NSView,
        window : NSWindow
    ) async throws {
        let sidebar = try splitPanes(in: hosting)[0]
        let names   = team.rows.map(\.name)
        try expect(
            names.count >= 2 && team.selectedWorker?.name == names.first,
            "the check needs the first of two workers selected, not \(team.selectedWorker?.name ?? "none")"
        )

        func isSidebarFocused() -> Bool {
            (window.firstResponder as? NSView)?.isDescendant(of: sidebar) ?? false
        }

        func responder() -> String { window.firstResponder.map { "\(type(of: $0))" } ?? "none" }

        func tab(
            backwards: Bool = false,
            _ label  : String
        ) async throws {
            press(
                backwards ? "\u{19}" : "\t",
                keyCode   : 48,
                modifiers : backwards ? [.shift] : [],
                in        : window,
                throughApp: false
            )
            try await Task.sleep(for: .milliseconds(300))
            print("click check: after \(label), first responder \(responder())")
        }

        func arrow(
            _ keyCode: UInt16,
            _ label  : String
        ) async throws {
            // Queued, as a real key is, so the selection sees a key down as the event that moved it.
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with                       : type,
                    location                   : .zero,
                    modifierFlags              : [.function, .numericPad],
                    timestamp                  : ProcessInfo.processInfo.systemUptime,
                    windowNumber               : window.windowNumber,
                    context                    : nil,
                    characters                 : "",
                    charactersIgnoringModifiers: "",
                    isARepeat                  : false,
                    keyCode                    : keyCode
                ) else { continue }

                NSApp.postEvent(
                    event,
                    atStart: false
                )
                if type == .keyDown { try await Task.sleep(for: .milliseconds(300)) }
            }
            try await Task.sleep(for: .milliseconds(400))
            print("click check: after \(label), selected \(team.selectedWorker?.name ?? "none"), first responder \(responder())")
        }

        window.makeFirstResponder(nil)
        try await tab("Tab")
        try expect(
            window.firstResponder is TranscriptCollectionView,
            "Tab from nothing did not reach the conversation, but \(responder())"
        )
        try await tab(
            backwards: true,
            "Shift-Tab"
        )
        try expect(
            window.firstResponder is NSTextView && isSidebarFocused(),
            "Shift-Tab from the conversation did not reach the search field, but \(responder())"
        )
        try await tab(
            backwards: true,
            "Shift-Tab again"
        )
        try expect(
            window.firstResponder is HouseRoomsKeyStop.StopView,
            "Shift-Tab from the search field did not reach the rooms, but \(responder())"
        )

        try await arrow(
            125,
            "Down"
        )
        try expect(
            team.selectedWorker?.name == names[1] && window.firstResponder is HouseRoomsKeyStop.StopView,
            "Down did not select \(names[1]) and keep the keyboard in the rooms"
        )
        try await arrow(
            126,
            "Up"
        )
        try expect(
            team.selectedWorker?.name == names[0],
            "Up did not return to \(names[0])"
        )
        try await tab("Tab from the rooms")
        try expect(
            window.firstResponder is NSTextView && isSidebarFocused(),
            "Tab from the rooms did not reach the search field, but \(responder())"
        )
        try await tab(
            backwards: true,
            "Shift-Tab back to the rooms"
        )
        try expect(
            window.firstResponder is HouseRoomsKeyStop.StopView,
            "Shift-Tab from the search field did not return to the rooms, but \(responder())"
        )
        press(
            "\r",
            keyCode   : 36,
            modifiers : [],
            in        : window,
            throughApp: false
        )
        try await Task.sleep(for: .milliseconds(300))
        print("click check: after Return, first responder \(responder())")
        try expect(
            window.firstResponder is ComposerTextView,
            "Return in the rooms did not hand the keyboard to the composer, but \(responder())"
        )

        // The rooms in reading order: the first across the sidebar's top, then two by two.
        let rooms = allViews(
            of: RoomLightView.self,
            in: sidebar
        ).map {
            $0.convert(
                $0.bounds,
                to: nil
            )
        }.sorted { $0.maxY != $1.maxY ? $0.maxY > $1.maxY : $0.minX < $1.minX }
        try expect(
            rooms.count >= 2,
            "the house shows \(rooms.count) rooms"
        )
        window.makeFirstResponder(nil)
        click(
            at: NSPoint(
                x: rooms[1].midX,
                y: rooms[1].midY
            ),
            in: window
        )
        try await Task.sleep(for: .seconds(1))
        let isComposerFocused = window.firstResponder is NSTextView && !isSidebarFocused()
        print("click check: after the click on the second room, selected \(team.selectedWorker?.name ?? "none"), "
            + "first responder \(responder())")
        try expect(
            team.selectedWorker?.name == names[1] && isComposerFocused,
            "clicking \(names[1]) did not select it and hand the keyboard to the composer"
        )
    }

    /// Nothing that hides a sidebar hides this one: the View menu has no item for
    /// it, and Control-Command-S, `toggleSidebar:` and a drag of the divider to
    /// the window's edge leave it shown at every sample, the drag at the compact width.
    private static func checkTheSidebarStays(
        hosting: NSView,
        window : NSWindow
    ) async throws {
        let items    = menuItems(NSApp.mainMenu)
        let viewMenu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.map(\.title) ?? []
        print("click check: View menu \(viewMenu)")

        let sidebarItems = items.filter {
            $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) || $0.title.contains("Sidebar")
        }
        for item in sidebarItems {
            print("click check: menu item \"\(item.title)\" in \"\(item.menu?.title ?? "none")\", action "
                + "\(item.action.map(NSStringFromSelector) ?? "none"), key \"\(item.keyEquivalent)\", "
                + "hidden \(item.isHidden), enabled \(item.isEnabled)")
        }

        // SwiftUI keeps a hidden Toggle Sidebar for Control-Command-S; the keys are tried below.
        let shown = sidebarItems.filter { !$0.isHidden }
        try expect(
            shown.isEmpty,
            "the menu bar offers \(shown.map(\.title))"
        )

        let width = try sidebarWidth(in: hosting)
        press(
            "s",
            keyCode   : 1,
            modifiers : [.control, .command],
            in        : window,
            throughApp: true
        )
        var narrowest = try await narrowestSidebar(
            in : hosting,
            for: .seconds(1)
        )
        print("click check: after Control-Command-S, sidebar narrowest \(narrowest)")
        try expect(
            narrowest == width,
            "Control-Command-S changed the sidebar from \(width) to \(narrowest)"
        )

        NSApp.sendAction(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            to  : nil,
            from: window
        )
        narrowest = try await narrowestSidebar(
            in : hosting,
            for: .seconds(1)
        )
        print("click check: after toggleSidebar:, sidebar narrowest \(narrowest)")
        try expect(
            narrowest == width,
            "toggleSidebar: changed the sidebar from \(width) to \(narrowest)"
        )

        let pane    = try splitPanes(in: hosting)[0]
        let divider = pane.convert(
            NSPoint(
                x: pane.bounds.maxX + 0.5,
                y: pane.bounds.midY
            ),
            to: nil
        )
        drag(
            from: divider,
            to  : NSPoint(
                x: 4,
                y: divider.y
            ),
            in  : window
        )
        narrowest = try await narrowestSidebar(
            in : hosting,
            for: .seconds(2)
        )
        let after = try sidebarWidth(in: hosting)
        print("click check: after dragging the divider to the edge, sidebar narrowest \(narrowest), now \(after)")
        try expect(
            narrowest >= ShellMetrics.compactSidebar - 1 && abs(after - ShellMetrics.compactSidebar) < 1,
            "the drag left the sidebar at \(after), narrowest \(narrowest)"
        )
    }

    /// Edit Worker… shows the inspector and puts the keyboard in the Worker section's Name field, not in
    /// the composer, for the selected worker and for another one chosen while the inspector is open.
    private static func checkEditWorker(
        team   : TeamModel,
        probe  : Probe,
        hosting: NSView,
        window : NSWindow
    ) async throws {
        let ids = team.rows.map(\.id)
        try expect(
            ids.count >= 2 && !probe.isInspectorRequested,
            "the check needs two workers and the inspector closed"
        )

        func isNameFieldFocused() -> Bool {
            guard let editor = window.firstResponder as? NSTextView, !(editor is ComposerTextView),
                  let field  = editor.delegate as? NSTextField
            else { return false }

            return field.placeholderString == "Worker name"
        }

        for (index, id) in [ids[0], ids[1]].enumerated() {
            window.makeFirstResponder(nil)
            team.editWorker(id)
            try await Task.sleep(for: .seconds(1.5))
            let responder = window.firstResponder.map { "\(type(of: $0))" } ?? "none"
            print("click check: after Edit Worker… \(index + 1), selected \(team.selectedWorker?.name ?? "none"), "
                + "inspector requested \(probe.isInspectorRequested), first responder \(responder)")
            try expect(
                team.selection == id && probe.isInspectorRequested && showsInspector(hosting),
                "Edit Worker… did not choose the worker and show the inspector"
            )
            try expect(
                isNameFieldFocused(),
                "Edit Worker… did not put the keyboard in the Name field, but \(responder)"
            )
            try expect(
                team.editingWorker == nil,
                "the Name field took the keyboard and left the request standing"
            )
        }

        press(
            "i",
            keyCode   : 34,
            modifiers : [.control, .option, .command],
            in        : window,
            throughApp: true
        )
        try await Task.sleep(for: .seconds(1))
        try expect(
            !probe.isInspectorRequested && !showsInspector(hosting),
            "the inspector did not close again"
        )
    }

    /// With the inspector open, a window too narrow for the full sidebar turns
    /// it compact, a wide one brings it back, and closing the inspector does too.
    private static func checkCompaction(
        probe  : Probe,
        hosting: NSView,
        window : NSWindow
    ) async throws {
        let full    = ShellMetrics.sidebar.ideal
        let compact = ShellMetrics.compactSidebar

        func expectDivision(
            _ label  : String,
            width    : Double,
            sidebar  : Double,
            inspector: Bool
        ) throws {
            let now = try sidebarWidth(in: hosting)
            print("click check: \(label): window \(window.frame.width), sidebar \(now), "
                + "inspector requested \(probe.isInspectorRequested)")
            try expect(
                abs(window.frame.width - width) < 1,
                "\(label): the window is \(window.frame.width) wide"
            )
            try expect(
                abs(now - sidebar) < 1,
                "\(label): the sidebar is \(now) wide, not \(sidebar)"
            )
            try expect(
                showsInspector(hosting) == inspector,
                "\(label): the inspector is not \(inspector ? "shown" : "hidden")"
            )
        }

        window.setContentSize(NSSize(
            width : 1000,
            height: 720
        ))
        try await Task.sleep(for: .seconds(1))
        press(
            "i",
            keyCode   : 34,
            modifiers : [.control, .option, .command],
            in        : window,
            throughApp: true
        )
        try await Task.sleep(for: .seconds(1))
        try expectDivision(
            "inspector opened at 1000",
            width    : 1000,
            sidebar  : compact,
            inspector: true
        )

        window.setContentSize(NSSize(
            width : 1200,
            height: 720
        ))
        try await Task.sleep(for: .seconds(1))
        try expectDivision(
            "widened to 1200",
            width    : 1200,
            sidebar  : full,
            inspector: true
        )

        // The narrowest window that holds the inspector, beside the compact sidebar.
        let narrowest = ShellMetrics.compactSidebar + ShellMetrics.inspector.ideal + ShellMetrics.conversationMinimum
        window.setContentSize(NSSize(
            width : narrowest,
            height: 720
        ))
        try await Task.sleep(for: .seconds(1))
        try expectDivision(
            "narrowed to \(Int(narrowest))",
            width    : narrowest,
            sidebar  : compact,
            inspector: true
        )

        press(
            "i",
            keyCode   : 34,
            modifiers : [.control, .option, .command],
            in        : window,
            throughApp: true
        )
        try await Task.sleep(for: .seconds(1))
        try expectDivision(
            "inspector closed at \(Int(narrowest))",
            width    : narrowest,
            sidebar  : full,
            inspector: false
        )

        window.setContentSize(NSSize(
            width : 1200,
            height: 720
        ))
        try await Task.sleep(for: .seconds(1))
    }

    // MARK: Geometry

    /// The sidebar pane's width, which throws once the pane is hidden or gone.
    private static func sidebarWidth(in root: NSView) throws -> Double {
        let split = firstView(
            of: NSSplitView.self,
            in: root
        )
        guard let split, let pane = split.arrangedSubviews.first,
              !pane.isHidden, pane.frame.width > 1, split.arrangedSubviews.count > 1
        else { throw CheckFailure(description: "the sidebar is hidden") }

        return Double(pane.frame.width)
    }

    /// The narrowest the sidebar was over `duration`, sampled every 50 ms, and 0 if it was ever hidden.
    private static func narrowestSidebar(
        in root     : NSView,
        for duration: Duration
    ) async throws -> Double {
        var narrowest = Double.infinity
        let clock     = ContinuousClock()
        let end       = clock.now + duration
        while clock.now < end {
            do {
                narrowest = min(
                    narrowest,
                    try sidebarWidth(in: root)
                )
            } catch {
                narrowest = 0
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return narrowest
    }

    /// Prints each split view controller's items under `root`, outermost first, which
    /// says on each macOS whether the inspector shares the sidebar's controller and
    /// whether `SidebarBridge` holds the sidebar's `canCollapse` false.
    private static func printSplitItems(in root: NSView) {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                let items = controller.splitViewItems.map {
                    "behavior \($0.behavior.rawValue) canCollapse \($0.canCollapse) collapsed \($0.isCollapsed)"
                }
                print("click check: \(type(of: controller)) items \(items)")
            }
            queue += view.subviews
        }
    }

    /// Every view of `type` under `root`, breadth first.
    private static func allViews<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> [View] {
        var found: [View] = []
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let match = view as? View { found.append(match) }
            queue += view.subviews
        }
        return found
    }

    /// The first view of `type` under `root`, breadth first.
    private static func firstView<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let match = view as? View { return match }
            queue += view.subviews
        }
        return nil
    }

    /// Every item of `menu` and of its submenus.
    private static func menuItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + menuItems($0.submenu) }
    }

    /// The shown panes of the outermost split view: the sidebar, the conversation and, when shown, the inspector.
    private static func splitPanes(in root: NSView) throws -> [NSView] {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView {
                return split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }
            }
            queue += view.subviews
        }
        throw CheckFailure(description: "no split view in the window")
    }

    /// The widths of every split view's shown panes, outermost first: the inspector may be a split of its own.
    private static func paneWidths(in root: NSView) -> [[Double]] {
        var widths: [[Double]] = []
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView {
                widths.append(split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }
                    .map { Double($0.frame.width) })
            }
            queue += view.subviews
        }
        return widths
    }

    /// Whether some pane is as wide as the inspector's range allows, which no other column is.
    private static func showsInspector(_ root: NSView) -> Bool {
        let widths = paneWidths(in: root)
        print("click check: pane widths \(widths)")
        let range = ShellMetrics.inspector.minimum...ShellMetrics.inspector.maximum
        return widths.joined().contains { range.contains($0) }
    }

    // MARK: Events

    /// A click queued as a real one is, so the app sees it as the current event when a selection moves.
    private static func click(
        at point : NSPoint,
        in window: NSWindow
    ) {
        print("click check: clicking \(point) in the window")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with         : type,
                location     : point,
                modifierFlags: [],
                timestamp    : ProcessInfo.processInfo.systemUptime,
                windowNumber : window.windowNumber,
                context      : nil,
                eventNumber  : 0,
                clickCount   : 1,
                pressure     : 1
            ) {
                NSApp.postEvent(
                    event,
                    atStart: false
                )
            }
        }
    }

    /// A drag from `start` to `end` in ten steps. A split view tracks a drag in
    /// its own loop, reading the queue, so the events are posted rather than sent.
    private static func drag(
        from start: NSPoint,
        to end    : NSPoint,
        in window : NSWindow
    ) {
        print("click check: dragging from \(start) to \(end) in the window")
        let steps = (1...10).map { step in
            NSPoint(
                x: start.x + (end.x - start.x) * CGFloat(step) / 10,
                y: start.y
            )
        }
        let events = [(NSEvent.EventType.leftMouseDown, start)] + steps.map { (.leftMouseDragged, $0) }
            + [(.leftMouseUp, end)]
        for (type, point) in events {
            if let event = NSEvent.mouseEvent(
                with         : type,
                location     : point,
                modifierFlags: [],
                timestamp    : ProcessInfo.processInfo.systemUptime,
                windowNumber : window.windowNumber,
                context      : nil,
                eventNumber  : 0,
                clickCount   : 1,
                pressure     : 1
            ) {
                NSApp.postEvent(
                    event,
                    atStart: false
                )
            }
        }
    }

    private static func press(
        _ key     : String,
        keyCode   : UInt16,
        modifiers : NSEvent.ModifierFlags,
        in window : NSWindow,
        throughApp: Bool
    ) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with                       : type,
                location                   : .zero,
                modifierFlags              : modifiers,
                timestamp                  : ProcessInfo.processInfo.systemUptime,
                windowNumber               : window.windowNumber,
                context                    : nil,
                characters                 : key,
                charactersIgnoringModifiers: key,
                isARepeat                  : false,
                keyCode                    : keyCode
            ) else { continue }

            // A shortcut is matched by the application's key equivalents; a plain key goes to the window.
            if throughApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
    }

    private static func expect(
        _ condition: Bool,
        _ failure  : String
    ) throws {
        guard condition else { throw CheckFailure(description: failure) }
    }
}
