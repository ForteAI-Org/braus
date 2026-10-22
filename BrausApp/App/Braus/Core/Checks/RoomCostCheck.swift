//
//  RoomCostCheck.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import ChatCore
import Darwin
import Memory
import Metal
import ModelTransports
import PerceptionCore
import SeatBroker
import SwiftUI

/// RoomCostCheck measures what the house's rooms cost, when the app is launched with
/// BRAUS_ROOM_COSTS set to a team's size (9, 30 or 60), and prints one line of JSON before it quits.
///
/// The team is synthetic, in a temporary store, as `WindowSnapshots`'s house of 30 and 60: every
/// seventh worker has no model (off), every fifth has an unread reply (waiting), every third of the
/// rest answers through a stand-in agent that only waits (busy), unless BRAUS_ROOM_COST_IDLE is set,
/// and the rest are free. The house window (`HouseShellView`) is 1200 points wide, or the narrowest
/// for BRAUS_ROOM_COST_MODE=compact; `rows` shows the rows. It is never ordered on screen unless
/// BRAUS_ROOM_COST_SHOW=1, and then never made key. BRAUS_ROOM_LIGHT picks the light as it does for
/// the app. Nothing is clicked or typed: the divider moves through its split view, the selection
/// through the team, the rooms scroll through their clip view.
///
/// Each event is timed until the rooms are quiet: no submission in flight and none for a second.
/// It records the rooms' GPU time by kind (`RoomCostLedger`), the main thread's busy time and its
/// longest stretch, the GPU's allocated memory, the process's footprint and the images the rooms keep.
/// At rest it records the process's CPU over ten seconds, the animations running and, on screen,
/// WindowServer's CPU with the window shown and ordered out. BRAUS_ROOM_COST_ONLY=appear stops after
/// the first appearance and the rest; `select` selects the worker at BRAUS_ROOM_COST_SELECT (1 unless
/// set), then the one at BRAUS_ROOM_COST_SWITCH if set, and records the rest with its conversation
/// open. BRAUS_ROOM_COST_REST sets the rest's seconds. Before that rest, BRAUS_ROOM_COST_USE, a list
/// split by commas, draws what the app draws once in a while: `image`, a flight's picture of a strip's
/// line (`BubbleFlight.image`); `copy`, a copy icon turned into a check and back
/// (`TranscriptRowView.replace`); `brain`, a Brain graph (`BrainGraphView`) in a window of its own
/// for five seconds, then closed, and `brain-history` one that grew over time, with its timeline.
///
/// BRAUS_ROOM_COSTS=kernel instead times the precomputed light alone, the live frame's cost: every
/// status, a few shapes, empty and occupied, at the grid's, the wide room's and a row's sizes at two
/// pixels per point, each drawn twenty times.
@MainActor
enum RoomCostCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["BRAUS_ROOM_COSTS"] != nil }

    private static var mode: String { ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_MODE"] ?? "rooms" }

    static func runAndQuit() async {
        let folder = URL.temporaryDirectory.appending(
            path         : "BrausRoomCosts-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var status: Int32 = 0
        var busy  : [UUID] = []
        var team  : TeamModel?

        if ProcessInfo.processInfo.environment["BRAUS_ROOM_COSTS"] == "kernel" {
            print("roomcosts: \(kernelCosts())")
            exit(0)
        }
        do {
            let count = Int(ProcessInfo.processInfo.environment["BRAUS_ROOM_COSTS"] ?? "") ?? 9
            UserDefaults.standard.set(
                mode == "rows" ? SidebarMode.rows.rawValue : SidebarMode.rooms.rawValue,
                forKey: AppPreferences.restylingSidebarMode
            )
            let made = try await makeTeam(
                count: count,
                in   : folder
            )
            team = made.team
            busy = made.busy
            let report = try await measure(
                made.team,
                count: count
            )
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options       : [.sortedKeys]
            )
            let line = String(
                decoding: data,
                as      : UTF8.self
            )
            print("roomcosts: \(line)")
        } catch {
            FileHandle.standardError.write(Data("room costs failed: \(error)\n".utf8))
            status = 1
        }
        for id in busy { team?.stopAnswering(id) }
        UserDefaults.standard.removeObject(forKey: AppPreferences.restylingSidebarMode)
        do { try FileManager.default.removeItem(at: folder) } catch {}
        exit(status)
    }

    // MARK: Events

    private static func measure(
        _ team: TeamModel,
        count : Int
    ) async throws -> [String: Any] {
        let busyWatch = MainThreadWatch()
        busyWatch.start()
        var report: [String: Any] = [
            "team"  : count,
            "mode"  : mode,
            "path"  : ProcessInfo.processInfo.environment["BRAUS_ROOM_LIGHT"] ?? "default",
            "camera": ProcessInfo.processInfo.environment["BRAUS_ROOM_CAMERA"] ?? "tilted",
        ]
        let width = mode == "compact" ? RestylingWindowLayout.minimumWidth : 1200

        var window: NSWindow
        let cold  : [String: Any]
        (window, cold) = try await appear(
            team,
            width: width,
            watch: busyWatch
        )
        report["appearCold"] = cold
        report["afterAppear"] = memory(in: window)
        if ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_ONLY"] == "select" {
            // At rest with a conversation open: the hero and its transcript beside the rooms.
            let ids   = team.rows.map(\.id)
            let index = Int(ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_SELECT"] ?? "") ?? 1
            report["select"] = try await event(
                busyWatch,
                window: window
            ) {
                team.selection = ids[min(index, ids.count - 1)]
            }
            if let other = Int(ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_SWITCH"] ?? "") {
                report["switch"] = try await event(
                    busyWatch,
                    window: window
                ) {
                    team.selection = ids[min(other, ids.count - 1)]
                }
            }
            try await use(ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_USE"] ?? "")
            report["restSelected"] = try await rest(in: window)
            window.close()
            return report
        }
        report["rest"] = try await rest(in: window)
        if ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_ONLY"] == "appear" {
            window.close()
            return report
        }

        if mode != "compact", let split = sidebarSplit(in: window) {
            report["resize"] = try await drag(
                split,
                from  : 280,
                to    : 330,
                window: window,
                watch : busyWatch
            )
            report["afterResize"] = memory(in: window)
            report["compaction"] = try await drag(
                split,
                from  : 280,
                to    : 180,
                window: window,
                watch : busyWatch,
                steps : 6
            )
            report["expansion"] = try await drag(
                split,
                from  : 180,
                to    : 280,
                window: window,
                watch : busyWatch,
                steps : 6,
                back  : false
            )
        }

        let ids = team.rows.map(\.id)
        if ids.count > 2 {
            report["select"] = try await event(
                busyWatch,
                window: window
            ) {
                team.selection = ids[1]
            }
            report["switch"] = try await event(
                busyWatch,
                window: window
            ) {
                team.selection = ids[2]
            }
            report["afterSelect"] = memory(in: window)
        }

        if let scroll = roomsScroll(in: window), scroll.documentView.map({ $0.frame.height > scroll.contentView.bounds.height + 1 }) == true {
            report["scrollDown"] = try await event(
                busyWatch,
                window: window
            ) {
                scrollToEnd(
                    scroll,
                    end: true
                )
            }
            report["afterScrollDown"] = memory(in: window)
            report["scrollUp"] = try await event(
                busyWatch,
                window: window
            ) {
                scrollToEnd(
                    scroll,
                    end: false
                )
            }
            report["afterScrollUp"] = memory(in: window)
        }

        window.contentView = nil
        window.close()
        try await pump(
            nil,
            for: 1
        )
        report["afterClose"] = memory(in: nil)
        let warm: [String: Any]
        (window, warm) = try await appear(
            team,
            width: width,
            watch: busyWatch
        )
        report["appearWarm"] = warm
        report["afterWarm"] = memory(in: window)
        window.contentView = nil
        window.close()
        return report
    }

    /// Draws what `list` names, as BRAUS_ROOM_COST_USE gives it.
    private static func use(_ list: String) async throws {
        for name in list.split(separator: ",") {
            switch name {
            case "image":
                _ = BubbleFlight.image(
                    of   : "A message quoted in the next one",
                    width: 300,
                    scale: 2
                )
            case "copy":
                // A copy icon turned into a check and back, as a code block's Copy does.
                let holder = NSView(frame: NSRect(
                    x     : 0,
                    y     : 0,
                    width : 100,
                    height: 100
                ))
                let icon   = NSImageView(frame: NSRect(
                    x     : 40,
                    y     : 40,
                    width : 20,
                    height: 20
                ))
                holder.wantsLayer = true
                icon.image        = NSImage(
                    systemSymbolName        : "doc.on.doc",
                    accessibilityDescription: nil
                )
                holder.addSubview(icon)
                let window = try await shown(holder)
                for symbol in ["checkmark", "doc.on.doc"] {
                    TranscriptRowView.replace(
                        icon,
                        with: NSImage(
                            systemSymbolName        : symbol,
                            accessibilityDescription: nil
                        ) ?? NSImage()
                    )
                    try await Task.sleep(for: .seconds(1.5))
                }
                window.contentView = nil
                window.close()
            case "brain", "brain-history":
                let simulation = BrainSimulation(graph: BrainGraph(brain: brain(grows: name == "brain-history")))
                let window     = try await shown(NSHostingView(rootView: BrainGraphView(simulation: simulation)))
                try await Task.sleep(for: .seconds(5))
                window.contentView = nil
                window.close()
            default:
                break
            }
        }
    }

    /// `view` in a window of its own beside the house, on screen for a second.
    private static func shown(_ view: NSView) async throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x     : 1280,
                y     : 40,
                width : 600,
                height: 500
            ),
            styleMask  : [.titled, .closable],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = NSAppearance(named: .darkAqua)
        window.contentView          = view
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(1))
        return window
    }

    /// A Brain of a group of six controls, learned one after another when it `grows`, so its graph
    /// has a timeline, or in one look.
    private static func brain(grows: Bool) -> UIBrain {
        let start   = Date(timeIntervalSince1970: 1_800_000_000)
        let group   = UUID()
        let anchors = (0..<6).map { index in
            ObjectAnchor(
                kind         : .control,
                label        : "Control \(index)",
                boundsTypical: NormalizedRect(
                    x     : 0,
                    y     : 0,
                    width : 0.1,
                    height: 0.1
                ),
                groupID      : group,
                firstSeen    : start.addingTimeInterval(grows ? Double(index) : 0),
                lastSeen     : start.addingTimeInterval(grows ? Double(index) : 0),
                window       : "main"
            )
        }
        return UIBrain(
            objects: anchors,
            groups : [
                SiblingGroup(
                    id           : group,
                    axis         : .column,
                    memberAnchors: anchors.map(\.anchorKey),
                    sharedKind   : .control,
                    cellSize     : NormalizedSize(
                        width : 0.1,
                        height: 0.1
                    ),
                    lastSeen     : start
                ),
            ]
        )
    }

    /// Hosts the house of `team` and reports what it cost until every room in sight had its full render
    /// and the rooms were quiet.
    private static func appear(
        _ team: TeamModel,
        width : Double,
        watch : MainThreadWatch
    ) async throws -> (window: NSWindow, report: [String: Any]) {
        _ = RoomCostLedger.take()
        watch.reset()
        let start  = CACurrentMediaTime()
        let window = host(
            team,
            width: width
        )
        let milestones = try await quiet(
            window,
            since  : start,
            renders: true,
            timeout: 180
        )
        var report = costs(
            RoomCostLedger.take(),
            watch: watch,
            since: start
        )
        report["shownMs"] = milestones.shown.map { milliseconds($0 - start) }
        report["fullMs"]  = milestones.full.map { milliseconds($0 - start) }
        return (window, report)
    }

    /// Runs `action`, then lays the window out at about 120 Hz until the rooms are quiet, and reports
    /// what that cost.
    private static func event(
        _ watch : MainThreadWatch,
        window  : NSWindow,
        renders : Bool = false,
        timeout : Double = 90,
        _ action: () -> Void
    ) async throws -> [String: Any] {
        _ = RoomCostLedger.take()
        watch.reset()
        let start = CACurrentMediaTime()
        action()
        let milestones = try await quiet(
            window,
            since  : start,
            renders: renders,
            timeout: timeout
        )
        let ledger = RoomCostLedger.take()
        var report = costs(
            ledger,
            watch: watch,
            since: start
        )
        report["shownMs"] = milestones.shown.map { milliseconds($0 - start) }
        report["fullMs"]  = milestones.full.map { milliseconds($0 - start) }
        return report
    }

    /// Moves the sidebar's divider from `from` to `to` and back in `steps` steps at 60 Hz, as a
    /// drag does, then waits for the rooms to settle: the drag's own costs, then the settle's.
    private static func drag(
        _ split: (view: NSSplitView, index: Int),
        from   : CGFloat,
        to     : CGFloat,
        window : NSWindow,
        watch  : MainThreadWatch,
        steps  : Int = 30,
        back   : Bool = true
    ) async throws -> [String: Any] {
        split.view.setPosition(
            from,
            ofDividerAt: split.index
        )
        try await quiet(
            window,
            since  : CACurrentMediaTime(),
            timeout: 90
        )
        _ = RoomCostLedger.take()
        watch.reset()
        let start = CACurrentMediaTime()
        let path  = (1...steps).map { from + (to - from) * CGFloat($0) / CGFloat(steps) }
            + (back ? (0..<steps).reversed().map { from + (to - from) * CGFloat($0) / CGFloat(steps) } : [])
        for position in path {
            split.view.setPosition(
                position,
                ofDividerAt: split.index
            )
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        let moving = RoomCostLedger.take()
        let live   = costs(
            moving,
            watch: watch,
            since: start
        )
        watch.reset()
        let settled = CACurrentMediaTime()
        try await quiet(
            window,
            since  : settled,
            timeout: 90
        )
        var report = costs(
            RoomCostLedger.take(),
            watch: watch,
            since: settled
        )
        report["moving"] = live
        report["steps"]  = path.count
        return report
    }

    /// Lays the window out at about 120 Hz until no room has a submission in flight and none came for
    /// a second since the first, or for three seconds when none came at all, or `timeout` seconds
    /// passed; when it `renders`, not before every room in sight had its full render. Returns when every
    /// room in sight first showed an image and when every one had a full render.
    @discardableResult
    private static func quiet(
        _ window: NSWindow,
        since   : CFTimeInterval,
        renders : Bool = false,
        timeout : Double
    ) async throws -> (shown: CFTimeInterval?, full: CFTimeInterval?) {
        var lastCount = RoomCostLedger.current.submitted
        var still     = CACurrentMediaTime()
        var started   = false
        let before    = Dictionary(
            rooms(in: window.contentView?.superview ?? NSView()).map { (ObjectIdentifier($0), $0.renderCounts) },
            uniquingKeysWith: { first, _ in first }
        )
        var shown: CFTimeInterval?
        var full : CFTimeInterval?
        while CACurrentMediaTime() - since < timeout {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(8))
            let visible = rooms(in: window.contentView?.superview ?? NSView()).filter(isShown)
            let counts  = visible.map { ($0.renderCounts, before[ObjectIdentifier($0)] ?? RoomLightView.RenderCounts()) }
            if shown == nil, !counts.isEmpty, counts.allSatisfy({ $0.0.live + $0.0.preview + $0.0.full > $0.1.live + $0.1.preview + $0.1.full }) {
                shown = CACurrentMediaTime()
            }
            if full == nil, !counts.isEmpty, counts.allSatisfy({ $0.0.full > $0.1.full }) {
                full = CACurrentMediaTime()
            }
            let ledger = RoomCostLedger.current
            let count  = ledger.submitted
            if count != lastCount || ledger.submitted != ledger.completed {
                lastCount = count
                still     = CACurrentMediaTime()
                started   = true
            } else if renders ? full != nil && CACurrentMediaTime() - still > 1
                              : CACurrentMediaTime() - still > (started ? 1 : 3) {
                return (shown, full)
            }
        }
        return (shown, full)
    }

    /// Lays `window` out, when there is one, for `seconds`.
    private static func pump(
        _ window: NSWindow?,
        for seconds: Double
    ) async throws {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            window?.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    /// The process's CPU over ten seconds at rest, the rooms' submissions meanwhile, and the
    /// animations running in the window.
    private static func rest(in window: NSWindow) async throws -> [String: Any] {
        _ = RoomCostLedger.take()
        let server = windowServerSeconds()
        let before = cpuSeconds()
        let start  = CACurrentMediaTime()
        let seconds = Double(ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_REST"] ?? "") ?? 10
        try await Task.sleep(for: .seconds(seconds))
        let cpu    = (cpuSeconds() - before) / (CACurrentMediaTime() - start)
        let serverCPU = server.flatMap { before in windowServerSeconds().map { ($0 - before) / (CACurrentMediaTime() - start) } }
        let ledger = RoomCostLedger.take()
        // On screen, WindowServer again with the window ordered out: the difference is its compositing.
        var hiddenServerCPU: Double?
        if window.isVisible {
            window.orderOut(nil)
            let hiddenStart = CACurrentMediaTime()
            let hidden      = windowServerSeconds()
            try await Task.sleep(for: .seconds(10))
            hiddenServerCPU = hidden.flatMap { before in
                windowServerSeconds().map { ($0 - before) / (CACurrentMediaTime() - hiddenStart) }
            }
            window.orderFrontRegardless()
            try await pump(
                window,
                for: 1
            )
        }
        var keys: [String: Int] = [:]
        if let layer = window.contentView?.superview?.layer {
            animations(
                in  : layer,
                into: &keys
            )
        }
        return [
            "windowServerPercent": serverCPU.map { ($0 * 1000).rounded() / 10 } ?? -1,
            "windowServerHiddenPercent": hiddenServerCPU.map { ($0 * 1000).rounded() / 10 } ?? -1,
            "cpuPercent" : (cpu * 1000).rounded() / 10,
            "submissions": ledger.completed,
            "animations" : keys.values.reduce(0, +),
            "byKey"      : keys,
        ]
    }

    private static func animations(
        in layer: CALayer,
        into keys: inout [String: Int]
    ) {
        for key in layer.animationKeys() ?? [] { keys[key, default: 0] += 1 }
        for sublayer in layer.sublayers ?? [] {
            animations(
                in  : sublayer,
                into: &keys
            )
        }
        if let mask = layer.mask {
            animations(
                in  : mask,
                into: &keys
            )
        }
    }

    // MARK: Measures

    /// The precomputed light's GPU time per room, in milliseconds, by camera and kind of room, as JSON.
    private static func kernelCosts() -> String {
        guard
            let device   = MTLCreateSystemDefaultDevice(),
            let renderer = PrecomputedRoomRenderer(device: device)
        else { return "{}" }
        let rooms: [(name: String, status: WorkerStatus, shape: WorkerShape, occupied: Bool, size: CGSize, lean: Float)] = [
            ("busy", .busy, .circle, true, CGSize(width: 127, height: 104), 0),
            ("free", .free, .square, true, CGSize(width: 260, height: 104), 0),
            ("waiting", .waiting, .triangle, true, CGSize(width: 127, height: 104), 0),
            ("off", .off, .diamond, true, CGSize(width: 127, height: 104), 0),
            ("empty", .busy, .circle, false, CGSize(width: 127, height: 104), 0),
            ("row", .busy, .hexagon, true, CGSize(width: 73, height: 73), 1),
        ]
        var report: [String: Double] = [:]
        for camera in [RoomCamera.tilted, .top] {
            var total = 0.0
            for room in rooms {
                let uniforms = RoomLightUniforms(
                    status     : room.status,
                    shape      : room.shape,
                    hasOccupant: room.occupied,
                    camera     : camera,
                    lean       : room.lean,
                    screenLit  : room.status == .busy
                )
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width      : Int(room.size.width) * 2,
                    height     : Int(room.size.height) * 2,
                    mipmapped  : false
                )
                descriptor.usage       = [.shaderWrite]
                descriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: descriptor) else { continue }
                var gpu = 0.0
                for index in 0..<21 {
                    guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { continue }
                    renderer.encode(
                        uniforms,
                        size         : room.size,
                        into         : texture,
                        commandBuffer: commandBuffer
                    )
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    // The first draw warms the pipeline.
                    if index > 0 { gpu += commandBuffer.gpuEndTime - commandBuffer.gpuStartTime }
                }
                report["\(camera)-\(room.name)"] = (gpu / 20 * 100_000).rounded() / 100
                total += gpu / 20
            }
            report["\(camera)-mean"] = (total / Double(rooms.count) * 100_000).rounded() / 100
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: report,
            options       : [.sortedKeys]
        )) ?? Data()
        return String(
            decoding: data,
            as      : UTF8.self
        )
    }

    private static func costs(
        _ ledger: RoomCostLedger.Ledger,
        watch   : MainThreadWatch,
        since   : CFTimeInterval
    ) -> [String: Any] {
        var kinds: [String: Any] = [:]
        var gpu = 0.0
        for (kind, total) in ledger.totals {
            kinds[kind.rawValue] = [
                "count": total.count,
                "gpuMs": milliseconds(total.gpu),
            ]
            gpu += total.gpu
        }
        return [
            "gpuMs"     : milliseconds(gpu),
            "kinds"     : kinds,
            "mainMs"    : milliseconds(watch.busy),
            "mainMaxMs" : milliseconds(watch.longest),
            "hitches"   : watch.hitches,
            "durationMs": milliseconds(max(0, (ledger.lastCompleted > since ? ledger.lastCompleted : since) - since)),
        ]
    }

    /// The GPU's allocated memory, the process's footprint, and the images every room keeps, in MB.
    private static func memory(in window: NSWindow?) -> [String: Any] {
        let rooms   = window.map { Self.rooms(in: $0.contentView?.superview ?? NSView()) } ?? []
        var seen    = Set<ObjectIdentifier>()
        var bytes   = 0
        var byRoom  : [Int] = []
        for room in rooms {
            var mine = 0
            for image in images(of: room) where seen.insert(ObjectIdentifier(image)).inserted {
                bytes += image.bytesPerRow * image.height
                mine  += image.bytesPerRow * image.height
            }
            byRoom.append(mine)
        }
        let device = MTLCreateSystemDefaultDevice()
        let visible = rooms.filter(isShown).count
        return [
            "gpuAllocatedMB": megabytes(device?.currentAllocatedSize ?? 0),
            "footprintMB"   : megabytes(footprint()),
            "imagesMB"      : megabytes(bytes),
            "maxRoomMB"     : megabytes(byRoom.max() ?? 0),
            "rooms"         : rooms.count,
            "visibleRooms"  : visible,
        ]
    }

    /// The images `room` keeps: its pulse, its body's and its passage's frames, and its last image.
    private static func images(of room: RoomLightView) -> [CGImage] {
        var images: [CGImage] = []
        let pulse = room.pulseLayer.animation(forKey: RoomLightView.pulseKey) as? CAKeyframeAnimation
        for value in pulse?.values ?? [] {
            if CFGetTypeID(value as CFTypeRef) == CGImage.typeID {
                images.append(unsafeBitCast(
                    value as AnyObject,
                    to: CGImage.self
                ))
            }
        }
        images += room.bodyFrames.values.flatMap { $0 }
        if let passage = room.passageFrames {
            images += passage.poses.values.flatMap { $0 } + passage.empty
        }
        if let shown = room.shownImage { images.append(shown) }
        for layer in [room.refineLayer, room.bodyFade, room.pulseLayer] {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                images.append(unsafeBitCast(
                    contents as AnyObject,
                    to: CGImage.self
                ))
            }
        }
        return images
    }

    /// Whether any of `room` shows, its visible rect taken within its bounds.
    private static func isShown(_ room: RoomLightView) -> Bool {
        room.window != nil && !room.isHiddenOrHasHiddenAncestor && !room.visibleRect.intersection(room.bounds).isEmpty
    }

    private static func rooms(in view: NSView) -> [RoomLightView] {
        var found: [RoomLightView] = []
        if let room = view as? RoomLightView { found.append(room) }
        for subview in view.subviews { found += rooms(in: subview) }
        return found
    }

    private static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 10_000).rounded() / 10
    }

    private static func megabytes(_ bytes: Int) -> Double {
        (Double(bytes) / 1_048_576 * 10).rounded() / 10
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(
            RUSAGE_SELF,
            &usage
        )
        let user   = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// The CPU time WindowServer has used, which composites the window's animations, as `ps` reads it.
    private static func windowServerSeconds() -> Double? {
        let process = Process()
        let pipe    = Pipe()
        process.executableURL  = URL(fileURLWithPath: "/bin/ps")
        process.arguments      = ["-axo", "time=,comm="]
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = output.split(separator: "\n").first(where: { $0.hasSuffix("/WindowServer") }) else { return nil }
        // "m:ss.ss" or "h:mm:ss".
        let parts = (line.split(separator: " ").first ?? "").split(separator: ":").compactMap { Double($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func footprint() -> Int {
        var info  = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to      : integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: The window

    /// The window's memory as plain state, as the house's snapshots keep it.
    private struct Root: View {

        let team: TeamModel

        @State var isInspectorRequested = false

        var body: some View {
            HouseShellView(
                team                : team,
                isInspectorRequested: $isInspectorRequested
            )
        }
    }

    /// The house of `team` in a window `width` by 900 that is never ordered on screen.
    private static func host(
        _ team: TeamModel,
        width : Double
    ) -> NSWindow {
        let appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = appearance
        let hosting = NSHostingView(rootView: Root(team: team))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(
                x     : 0,
                y     : 0,
                width : width,
                height: 900
            ),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = appearance
        window.contentView          = hosting
        window.setContentSize(NSSize(
            width : width,
            height: 900
        ))
        if ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_SHOW"] == "1" {
            window.setFrameOrigin(NSPoint(
                x: 40,
                y: 40
            ))
            window.orderFrontRegardless()
        }
        return window
    }

    /// The split view whose leading column holds the rooms, and the divider after that column.
    private static func sidebarSplit(in window: NSWindow) -> (view: NSSplitView, index: Int)? {
        guard let scroll = roomsScroll(in: window), let room = rooms(in: scroll).first else { return nil }
        var view: NSView? = room
        while let current = view, let parent = current.superview {
            if let split = parent as? NSSplitView, let index = split.arrangedSubviews.firstIndex(of: current),
               index < split.arrangedSubviews.count - 1 {
                return (split, index)
            }
            view = parent
        }
        return nil
    }

    /// The scroll view the rooms or the rows scroll in: the one that holds most rooms.
    private static func roomsScroll(in window: NSWindow) -> NSScrollView? {
        let scrolls = rooms(in: window.contentView?.superview ?? NSView()).compactMap(\.enclosingScrollView)
        return scrolls.max { first, second in
            scrolls.filter { $0 === first }.count < scrolls.filter { $0 === second }.count
        }
    }

    private static func scrollToEnd(
        _ scroll: NSScrollView,
        end     : Bool
    ) {
        let clip     = scroll.contentView
        let document = scroll.documentView?.frame.height ?? 0
        let far      = max(
            0,
            document - clip.bounds.height
        )
        let y        = clip.isFlipped == end ? far : 0
        clip.scroll(to: NSPoint(
            x: clip.bounds.minX,
            y: y
        ))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: The team

    /// `count` workers as the house's snapshots of 30 and 60 make them, with every third of the
    /// configured, read workers answering through a stand-in agent that waits half an hour.
    private static func makeTeam(
        count    : Int,
        in folder: URL
    ) async throws -> (team: TeamModel, busy: [UUID]) {
        try FileManager.default.createDirectory(
            at                         : folder,
            withIntermediateDirectories: true
        )
        let agent = folder.appending(path: "claude")
        try Data(standIn.utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )
        let store     = try WorkspaceStore.opening(in: folder.appending(
            path         : "Store",
            directoryHint: .isDirectory
        ))
        let selection = ModelSelection(
            provider: .claudeCode,
            model   : "claude-opus-5",
            effort  : .high
        )
        let palettes = ["dusk", "tide", "ember", "dawn"]
        var busy: [UUID] = []

        for index in 0..<count {
            let worker = try await store.createWorker(
                name      : "Worker \(index + 1)",
                role      : "Role \(index % 9 + 1)",
                appearance: WorkerAppearance(
                    seed   : Int64(index * 7 + 3),
                    palette: palettes[index % palettes.count]
                )
            )
            guard index % 7 != 6 else { continue }

            try await store.configure(
                worker   : worker.id,
                selection: selection
            )
            if index % 5 == 4 {
                let conversation = try await store.createConversation(
                    kind        : .direct,
                    participants: [worker.id]
                )
                try await store.appendMessage(
                    to      : conversation.id,
                    author  : worker.id,
                    text    : "Done.",
                    delivery: .completed
                )
            } else if index % 3 == 0, ProcessInfo.processInfo.environment["BRAUS_ROOM_COST_IDLE"] == nil {
                busy.append(worker.id)
            }
        }

        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent
        )
        await team.load()
        for id in busy {
            team.selection = id
            await team.openSelectedConversation()
            team.draft = "Wait."
            await team.send()
        }
        team.selection = nil
        for _ in 0..<500 where !busy.allSatisfy(team.isAnswering) {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (team, busy)
    }

    /// A stand-in agent that starts and then only waits, so its worker stays busy.
    private static let standIn = """
        #!/usr/bin/python3
        import json, sys, time
        sys.stdin.read()
        print(json.dumps({'type': 'system', 'subtype': 'init', 'model': 'claude-opus-5', 'session_id': 's1'}), flush=True)
        time.sleep(1800)

        """

    /// MainThreadWatch adds up how long the main run loop is busy between waits, and its longest
    /// stretch, from a run loop observer.
    private final class MainThreadWatch {

        private(set) var busy    = 0.0
        private(set) var longest = 0.0
        private(set) var hitches = 0

        private var woke: CFTimeInterval?
        private var observer: CFRunLoopObserver?

        func start() {
            observer = CFRunLoopObserverCreateWithHandler(
                nil,
                CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                true,
                0
            ) { [weak self] _, activity in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    self.woke = now
                } else if let woke = self.woke {
                    let span = now - woke
                    self.busy   += span
                    self.longest = max(
                        self.longest,
                        span
                    )
                    if span > 1.0 / 60 { self.hitches += 1 }
                    self.woke = nil
                }
            }
            CFRunLoopAddObserver(
                CFRunLoopGetMain(),
                observer,
                .commonModes
            )
        }

        func reset() {
            busy    = 0
            longest = 0
            hitches = 0
        }
    }
}

