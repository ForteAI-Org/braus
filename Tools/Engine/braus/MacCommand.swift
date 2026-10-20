import CoreGraphics
import EngineCore
import Foundation
import MacDelivery
import MacDriver
import MacDriving
import PerceptionCore

/// MacCommand drives the MacDriver's reading side by hand: open an app in the background, list its
/// windows, read one window as a scene, or record its tree as a test fixture. Nothing here acts on
/// the app beyond launching it.
///
///   braus mac open <app>                          launch without activation, report the first window
///   braus mac windows <app>                       the app's windows, front to back
///   braus mac read <app> [--window <n>] [--limit <n>]   one window's scene, coverage and read cost
///   braus mac record <app> <file.json> [--window <n>] [--all]   the window's tree as JSON, for tests;
///                                                 --all reads every child, not only the visible ones
///   braus mac pane <name|extension id>            show a System Settings pane, app behind
///   braus mac reveal <path>                       select a file in a Finder window, Finder behind
///   braus mac open-with <path> [<app>]            open a file with an app (or its default), app behind
///   braus mac act <app> <label> [--pause]         click the element named <label>, app behind; prints the rung;
///                                                 --pause waits 6 s between the read and the gesture
///   braus mac type <app> <label> <text>           focus the field named <label> and type <text>, app behind
///   braus mac key <app> <character> [--command] [--shift] [--option]   a shortcut to the app's window
///   braus mac scroll <app> <label> [up|down]      scroll the area under the element, app behind
///   braus mac person-check [--wait]               which processes the person's input reached (8 s with --wait)
enum MacCommand {

    static func run(_ invocation: Invocation) async throws {
        let reader = LiveMacTreeReader()
        let launcher = MacLauncher(workspace: LiveMacWorkspace(), reader: reader)
        let action = try invocation.positional(0, "open|windows|read|record|pane|reveal|open-with")
        let opener = MacBackgroundOpener(launcher: launcher)
        switch action {
            case "person-check":
                // Three zero-pixel scrolls through the HID stream: they move nothing.
                let watch = LiveMacPersonWatch()
                for _ in 0..<3 {
                    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)?
                        .post(tap: .cghidEventTap)
                }
                try await Task.sleep(for: .seconds(invocation.flags.contains("wait") ? 8 : 0.5))
                let now = ContinuousClock.now
                return print("watch \(watch.isWatching ? "on" : "off"): " + watch.touches.map { "pid \($0.key) \(now - $0.value) ago" }
                    .joined(separator: ", "))
            case "pane":
                return print(describe(try await opener.openSettingsPane(try invocation.positional(1, "<pane>"))))
            case "reveal":
                return print(describe(try await opener.reveal(try invocation.positional(1, "<path>"))))
            case "open-with":
                let app = invocation.positionals.count > 2 ? invocation.positionals[2] : nil
                return print(describe(try await opener.open(try invocation.positional(1, "<path>"), with: app)))
            default:
                break
        }
        let app = try launcher.resolve(try invocation.positional(1, "<app>"))
        if ["act", "type", "key", "scroll"].contains(action) {
            guard let running = launcher.workspace.running(bundleID: app.bundleID) else {
                throw UsageError.invalid(option: action, value: app.displayName, expected: "a running app (braus mac open)")
            }
            return try await act(action, invocation, processID: running.processID)
        }

        if action == "open" {
            print(describe(try await launcher.open(app.bundleID)))
            return
        }
        guard let running = launcher.workspace.running(bundleID: app.bundleID) else {
            throw UsageError.invalid(option: action, value: app.displayName, expected: "a running app (braus mac open)")
        }
        let windows = try await reader.windows(of: running.processID)
        switch action {
            case "windows":
                for window in windows { print(describe(window)) }
            case "read":
                var limits = MacTreeLimits.standard
                if let limit = invocation.options["limit"].flatMap(Int.init) { limits.elementLimit = limit }
                let index = try windowIndex(invocation, windows)
                let read = try await reader.read(windowAt: index, of: running.processID, limits: limits)
                let scene = MacSceneBuilder.scene(from: read, bundleID: app.bundleID, appName: app.displayName)
                print(describe(scene))
            case "record":
                let path = try invocation.positional(2, "<file.json>")
                var limits = MacTreeLimits.standard
                if invocation.flags.contains("all") { limits = MacTreeLimits(elementLimit: 1_500, visibleOnly: false) }
                let read = try await reader.read(windowAt: try windowIndex(invocation, windows), of: running.processID,
                                           limits: limits)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(read.window).write(to: URL(fileURLWithPath: path))
                print("\(read.nodesVisited) elements, \(String(format: "%.2f", read.duration)) s -> \(path)")
            default:
                throw UsageError.invalid(option: "mac", value: action, expected: "open, windows, read or record")
        }
    }

    /// One gesture through the MacDriver's own roles: scene, ladder, settler, read-back.
    private static func act(_ action: String, _ invocation: Invocation, processID: pid_t) async throws {
        let cache = MacSceneCache()
        let scenes = MacScenes(cache: cache)
        let person = LiveMacPersonWatch()
        let actuator = MacActuator(cache: cache, actor: LiveMacTreeReader(), delivery: MacInPlaceDelivery(), person: person)
        if !person.isWatching { print("person watch off: no Input Monitoring permission; rule 6 not enforced") }
        let settler = MacSettler(source: LiveMacNotificationSource())
        let before = try await scenes.scene(of: processID).perceived

        var gestures: [Gesture] = []
        var target: SceneElement?
        if action == "key" {
            let text = try invocation.positional(2, "<character>")
            guard let character = text.first else { throw UsageError.invalid(option: "key", value: text, expected: "a character") }
            var modifiers: KeyModifiers = []
            if invocation.flags.contains("command") { modifiers.insert(.command) }
            if invocation.flags.contains("shift")   { modifiers.insert(.shift) }
            if invocation.flags.contains("option")  { modifiers.insert(.option) }
            gestures = [.character(character, modifiers: modifiers)]
        } else {
            let label = try invocation.positional(2, "<label>")
            guard let element = before.scene.elements.first(where: { $0.label == label || $0.role == label }) else {
                throw UsageError.invalid(option: action, value: label, expected: "the label of an element in braus mac read")
            }
            target = element
            gestures = [.click(at: before.globalPoint(of: element))]
            if action == "type" { gestures.append(.type(try invocation.positional(3, "<text>"))) }
            if action == "scroll" {
                let up = (invocation.positionals.count > 3 ? invocation.positionals[3] : "down") == "up"
                gestures = [.scroll(at: before.globalPoint(of: element), deltaY: up ? 5 : -5)]
            }
        }

        if invocation.flags.contains("pause") {
            print("scene read; acting in 6 s")
            try await Task.sleep(for: .seconds(6))
            let now = ContinuousClock.now
            print("person watch \(person.isWatching ? "on" : "off"); touched: "
                  + person.touches.map { "pid \($0.key) \(now - $0.value) ago" }.joined(separator: ", ")
                  + "; this app pid \(processID)")
        }
        let clock = ContinuousClock()
        for gesture in gestures {
            await settler.prepare(in: processID)
            let started = clock.now
            try await actuator.perform(gesture, in: processID)
            let delivered = clock.now - started
            await settler.settle(in: processID, cap: .seconds(2))
            let settled = clock.now - started
            if let note = actuator.lastDelivery(in: processID) {
                print("rung \(note.rung.rawValue): \(note.how)" + (note.skipped.isEmpty ? "" : " (skipped: \(note.skipped.joined(separator: "; ")))")
                      + " delivered \(delivered), settled \(settled)")
            }
            _ = try await scenes.scene(of: processID)
        }
        let after = try await scenes.scene(of: processID).perceived
        if let target, let now = after.scene.elements.first(where: { $0.id == target.id }) {
            print("read-back \(now.id) \"\(now.label)\"" + (now.value.map { " = \"\($0.prefix(60))\"" } ?? "")
                  + (now.state.map { " [\($0.rawValue)]" } ?? ""))
        }
        let changed = Set(after.scene.elements.map { "\($0.label)=\($0.value ?? "")" })
            .symmetricDifference(Set(before.scene.elements.map { "\($0.label)=\($0.value ?? "")" }))
        print("scene: \(before.scene.elements.count) -> \(after.scene.elements.count) elements, \(changed.count) changed")
        for line in changed.sorted().prefix(8) { print("  ~ \(line.prefix(80))") }
    }

    private static func windowIndex(_ invocation: Invocation, _ windows: [MacWindowSummary]) throws -> Int {
        if let text = invocation.options["window"] {
            guard let index = Int(text), windows.indices.contains(index) else {
                throw UsageError.invalid(option: "window", value: text, expected: "an index from braus mac windows")
            }
            return index
        }
        guard let window = windows.first(where: \.isFocused) ?? windows.first(where: \.isMain) ?? windows.first else {
            throw MacTreeFailure.windowNotFound(index: 0)
        }
        return window.index
    }

    private static func describe(_ window: MacWindowSummary) -> String {
        let flags = [window.isFocused ? "focused" : nil, window.isMain ? "main" : nil,
                     window.isMinimized ? "minimized" : nil].compactMap { $0 }
        let frame = window.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
        let document = window.document.map { " doc \($0)" } ?? ""
        return "[\(window.index)] \(window.role)/\(window.subrole ?? "-") \"\(window.title ?? "")\" \(frame) \(flags.joined(separator: " "))\(document)"
    }

    private static func describe(_ report: MacLaunchReport) -> String {
        var lines = [
            "\(report.app.displayName) (\(report.app.bundleID)) pid \(report.processID)"
                + (report.wasRunning ? ", already running" : ", launched"),
            "window: " + (report.window.map(describe) ?? "none after \(String(format: "%.1f", report.secondsWaited)) s"),
            String(format: "waited %.2f s; self-activated %@; focus restored %@; person acted %@",
                   report.secondsWaited, "\(report.selfActivated)", "\(report.focusRestored)",
                   "\(report.personActedMeanwhile)"),
        ]
        if let sheet = report.sheet {
            lines.append("sheet: \"\(sheet.title ?? "")\" buttons: \(sheet.buttons.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ report: MacOpenReport) -> String {
        [
            "\(report.operation): " + (report.reason.map { "acted, unverified: \($0)" } ?? "verified"),
            "route: \(report.route)",
            "\(report.app.displayName) pid \(report.processID), window: " + (report.window.map(describe) ?? "none"),
            String(format: "%.2f s; self-activated %@; focus restored %@; person acted %@", report.focus.elapsed,
                   "\(report.focus.selfActivated)", "\(report.focus.focusRestored)", "\(report.focus.personActed)"),
        ].joined(separator: "\n")
    }

    private static func describe(_ scene: MacScene) -> String {
        let quality = scene.perceived.capture
        var lines = [
            "\"\(scene.perceived.scene.windowTitle)\" \(scene.perceived.surface.rawValue): "
                + "\(scene.nodesVisited) read, \(scene.perceived.scene.elements.count) elements, "
                + "\(scene.nodesSkippedOffscreen) off-screen skipped, "
                + String(format: "%.2f s", scene.readDuration)
                + (quality.stoppedBy.map { ", stopped by \($0.rawValue)" } ?? ", complete"),
            String(format: "coverage %.0f%%, %d actionable: %@", scene.coverage.coveredShare * 100,
                   scene.coverage.actionableCount, scene.coverage.isRich ? "MacDriver" : "sparse"),
            "sections: " + scene.perceived.scene.sections.map(\.name).joined(separator: ", "),
        ]
        for element in scene.perceived.scene.elements {
            var text = "  \(element.id) \(element.role ?? element.kind.rawValue) \"\(element.label)\""
            if let value = element.value { text += " = \"\(value.prefix(40))\"" }
            if let state = element.state { text += " [\(state.rawValue)]" }
            if element.isEnabled == false { text += " disabled" }
            if let section = element.section { text += " @\(section)" }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}
