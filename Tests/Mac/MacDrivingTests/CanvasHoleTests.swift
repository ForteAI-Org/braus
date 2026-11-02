//
//  CanvasHoleTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import IncrementalText
import MacDriver
@testable import Perception
@testable import PerceptionCore
import Testing

/// Canvases where accessibility has no element at all: a window whose drawn view is a hole in its
/// tree. The layout is a DAW edit window's, frames copied from read-only accessibility dumps (Pro Tools,
/// 2/11/2026): named track groups end at x 1263 and the playlist right of them has no element.
@Suite("Canvases in holes of the accessibility tree")
struct CanvasHoleTests {

    /// The window in global points.
    static let window = CGRect(x: -3, y: 39, width: 1515, height: 923)
    static let tracks: [(name: String, kind: String, y: CGFloat)] = [
        ("Drums folder", "Routing Folder Track", 240), ("Crash 1", "Audio Track", 337),
        ("Kick 1", "Audio Track", 434), ("Snare fill", "Audio Track", 531), ("Tom 1", "Audio Track", 628),
        ("Bass folder", "Routing Folder Track", 737), ("Bass 1", "Audio Track", 834),
        ("Perc folder", "Routing Folder Track", 943), ("Cymbal", "Audio Track", 1040),
        ("Maraca 1", "Audio Track", 1137), ("Synth folder", "Routing Folder Track", 1246),
        ("Synth 1", "Audio Track", 1343), ("ElGtr folder", "Routing Folder Track", 1452),
        ("Electric guitar", "Audio Track", 1549), ("Keys folder", "Routing Folder Track", 1658),
        ("Piano 1", "Audio Track", 1755), ("Mix Print", "Routing Folder Track", 1864),
        ("Master Print", "Routing Folder Track", 1967),
    ]

    // MARK: Tree

    static func node(
        _ role  : String,
        _ name  : String? = nil,
        _ frame : (CGFloat, CGFloat, CGFloat, CGFloat),
        value   : String? = nil,
        children: [MacTreeNode] = []
    ) -> MacTreeNode {
        MacTreeNode(
            role    : role,
            title   : name,
            value   : value,
            frame   : CGRect(x: frame.0, y: frame.1, width: frame.2, height: frame.3),
            children: children
        )
    }

    /// A named column group of a track header with `count` named buttons laid out inside it.
    static func column(_ name: String, x: CGFloat, y: CGFloat, width: CGFloat, count: Int) -> MacTreeNode {
        let columns = count >= 6 ? 2 : 1
        let rows = max(1, (count + columns - 1) / columns)
        let kids = (0..<count).map { index in
            node("AXButton", "\(name) \(index + 1)", (
                x + CGFloat(index % columns) * width / CGFloat(columns),
                y + CGFloat(index / columns) * (97 / CGFloat(rows)).rounded(.down),
                width / CGFloat(columns),
                (97 / CGFloat(rows)).rounded(.down)
            ))
        }
        return node("AXGroup", name, (x, y, width, 97), children: kids)
    }

    /// One track header: the controls and column groups of the dump's track, moved to row `y`.
    static func track(_ name: String, kind: String, y: CGFloat) -> MacTreeNode {
        node("AXGroup", "\(name) - \(kind) ", (202, y, 1061, 97), children: [
            node("AXPopUpButton", "Track name\n\"\(name)\"", (232, y + 1, 98, 16)),
            node("AXPopUpButton", "Playlist selector", (330, y + 1, 12, 16)),
            node("AXButton", "Track Record Enable", (238, y + 19, 20, 20)),
            node("AXButton", "Input monitoring disabled", (264, y + 19, 20, 20)),
            node("AXButton", "Solo", (290, y + 19, 20, 20)),
            node("AXButton", "Mute", (316, y + 19, 20, 20)),
            node("AXPopUpButton", "Track View selector", (234, y + 40, 105, 17)),
            node("AXPopUpButton", "Timebase selector (samples)", (234, y + 76, 13, 17)),
            node("AXButton", "Not Frozen", (234, y + 58, 13, 17)),
            node("AXPopUpButton", "Elastic Audio or ARA Plugin selector", (248, y + 76, 13, 17)),
            node("AXPopUpButton", "Current Elastic Audio or ARA Plugin", (261, y + 76, 78, 17)),
            node("AXPopUpButton", "Voice selector\ndyn", (248, y + 58, 31, 17)),
            node("AXPopUpButton", "Automation Mode selector", (280, y + 58, 59, 17)),
            node("AXPopUpButton", "Track options", (218, y + 2, 12, 12)),
            node("AXDisclosureTriangle", "Show/hide automation lanes", (219, y + 83, 11, 11)),
            node("AXButton", nil, (345, y + 2, 14, 93)),
            node("AXTextField", "Comments \"\"", (362, y + 3, 96, 91)),
            column("Inserts A-E", x: 610, y: y, width: 75, count: 10),
            column("Inserts F-J", x: 685, y: y, width: 75, count: 10),
            column("Sends A-E", x: 760, y: y, width: 75, count: 10),
            column("Sends F-J", x: 835, y: y, width: 75, count: 10),
            column("Audio IO", x: 910, y: y, width: 85, count: 6),
            column("Mic Pre", x: 460, y: y, width: 75, count: 0),
            column("Object", x: 995, y: y, width: 85, count: 6),
            column("Markers View", x: 1226, y: y, width: 22, count: 3),
        ])
    }

    /// The edit window's tree: toolbar clusters, the track and group lists, the track headers and the
    /// controls around the playlist, which itself has no node.
    static var tree: MacTreeNode {
        let clusters: [(String, (CGFloat, CGFloat, CGFloat, CGFloat))] = [
            ("Edit Mode Cluster", (-3, 67, 130, 83)), ("Zoom Quadrant Cluster", (127, 67, 105, 83)),
            ("Cursor Tool Cluster", (232, 67, 325, 83)), ("Counter Display Cluster", (557, 67, 338, 83)),
            ("Grid/Nudge Cluster", (895, 67, 166, 83)), ("Quantize Cluster", (1596, 67, 221, 84)),
            ("Transport View Cluster", (1061, 67, 326, 84)), ("MIDI Control Cluster", (1387, 67, 157, 84)),
        ]
        let rows = (0..<18).map { index in
            node("AXRow", nil, (1, 178 + CGFloat(index) * 11, 180, 11))
        }
        let children: [MacTreeNode] = clusters.map { name, frame in
            node("AXGroup", name, frame, children: [
                node("AXButton", "\(name) control", (frame.0 + 10, frame.1 + 20, 40, 20)),
            ])
        } + [
            node("AXButton", "ToolbarOptionsMenu", (1492, 73, 17, 18)),
            node("AXTable", "Track List", (1, 178, 180, 198), children: rows),
            node("AXStaticText", nil, (6, 159, 196, 19), value: "TRACKS"),
            node("AXButton", "Track List pop-up", (178, 157, 17, 18)),
            node("AXTable", "Group List", (1, 835, 180, 13), children: [node("AXRow", nil, (1, 835, 180, 13))]),
            node("AXStaticText", nil, (6, 816, 196, 19), value: "GROUPS"),
            node("AXButton", "Group List pop-up", (178, 814, 17, 18)),
            node("AXButton", "Groups Keyboard Focus", (182, 835, 15, 15)),
            node("AXButton", "Linearity Display Mode", (332, 219, 26, 13)),
            node("AXButton", "Edit Window View selector", (202, 219, 30, 14)),
            node("AXStaticText", nil, (202, 200, 1061, 17)),
            node("AXButton", "Show/Hide SessionView", (1492, 200, 15, 16)),
            node("AXButton", "Edit Keyboard Focus", (1492, 219, 15, 15)),
        ] + tracks.map { track($0.name, kind: $0.kind, y: $0.y) } + [
            node("AXButton", "Audio Zoom In", (1492, 234, 15, 21)),
            node("AXButton", "MIDI Zoom In", (1492, 255, 15, 21)),
            node("AXSlider", "Slider", (1602, 910, 232, 16)),
            node("AXButton", "Track List Show/Hide", (202, 917, 15, 15)),
            node("AXButton", "Hide Lower Dock", (217, 917, 15, 15)),
            node("AXStaticText", nil, (232, 917, 1031, 15)),
            node("AXButton", "Show/Hide Clip List", (1477, 917, 15, 15)),
            node("AXRadioButton", "MIDI EDITOR", (24, 938, 78, 22)),
            node("AXRadioButton", "CLIP EFFECTS", (102, 938, 106, 22)),
            node("AXRadioButton", "MELODYNE", (208, 938, 91, 22)),
            node("AXRadioButton", "RX SPECTRAL EDITOR", (299, 938, 146, 22)),
            node("AXPopUpButton", "Lower Dock view selector", (4, 939, 17, 18)),
            node("AXButton", nil, (7, 46, 12, 14)),
            node("AXButton", nil, (47, 46, 12, 14)),
            node("AXButton", nil, (27, 46, 12, 14)),
            node("AXStaticText", nil, (702, 44, 123, 16), value: "Edit: Session"),
        ]
        return node("AXWindow", "Edit: Session", (-3, 39, 1515, 923), children: children).addressed()
    }

    // MARK: Image

    /// The window at 1x: one flat grey everywhere but the playlist, where each lane holds a clip.
    static func image() throws -> CGImage {
        let width = Int(window.width), height = Int(window.height)
        let context = try #require(CGContext(
            data            : nil,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Window points to the context's bottom-left pixels.
        func fill(_ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(
                x     : rect.minX - window.minX,
                y     : window.maxY - rect.maxY,
                width : rect.width,
                height: rect.height
            ))
        }
        fill(window, 0.15, 0.15, 0.15)
        for (index, track) in tracks.enumerated() where track.y < window.maxY {
            let start = 1270 + CGFloat(index * 37 % 120)
            fill(CGRect(x: start, y: track.y + 8, width: 90, height: 80), 0.3, 0.35, 0.8)
        }
        return try #require(context.makeImage())
    }

    // MARK: Scene

    static func scene() async throws -> (scene: SceneSnapshot, harvest: AccessibilityHarvest) {
        let harvest = AccessibilityAugmentation.harvest(
            under      : tree,
            windowFrame: window,
            reader     : CanvasFixtures.Reader()
        )
        let pipeline = ScenePipeline(
            text        : CanvasDetectionTests.NoText(),
            augmentation: CanvasDetectionTests.RecordedAugmenter(harvest: harvest)
        )
        let scene = try await pipeline.capture(
            try image(),
            of: ScenePipeline.Window(
                bundleID : "com.braus.fixture.hole",
                appName  : "Hole Fixture",
                title    : "Edit: Session",
                processID: 1,
                frame    : window
            )
        ).scene
        return (scene, harvest)
    }

    /// A canvas's frame in global points.
    static func frame(of canvas: SceneElement) -> CGRect {
        canvas.bounds.pixelBox(in: window.size).offsetBy(dx: window.minX, dy: window.minY)
    }

    @Test("The playlist no element covers is the one canvas; the plain track list area is not")
    func playlistIsACanvas() async throws {
        let (scene, harvest) = try await Self.scene()
        #expect(harvest.quality.walkCompleted == true)
        #expect(!harvest.elements.contains { $0.kind == .canvas })
        // Two holes pass the geometry: the playlist strip, then the empty area under the track list.
        #expect(harvest.uncoveredCanvases.map(\.label) == ["canvas 1", "canvas 2"])
        let canvases = scene.elements.filter { $0.kind == .canvas }
        #expect(canvases.map(\.id) == ["canvas|canvas1"])
        let canvas = try #require(canvases.first)
        #expect(canvas.role == nil)
        let frame = Self.frame(of: canvas)
        // Within a grid cell of the hole: right of the track groups, left of the zoom buttons.
        #expect((1263...1271).contains(frame.minX), "\(frame)")
        #expect((1477...1492).contains(frame.maxX), "\(frame)")
        #expect(frame.minY <= 240 && frame.maxY >= 917, "\(frame)")
        #expect(scene.text().contains("[canvas] canvas 1 "))
        print("HOLE_FRAME \(frame) of window \(Self.window)")
    }

    @Test("No holes from a walk a limit cut short: unread nodes would read as holes")
    func cutWalkHasNoHoles() {
        let harvest = AccessibilityAugmentation.harvest(
            under      : Self.tree,
            windowFrame: Self.window,
            reader     : CanvasFixtures.Reader(),
            limits     : AccessibilityAugmentation.Limits(maxElements: 40)
        )
        #expect(harvest.quality.stoppedBy == .elementLimit)
        #expect(harvest.uncoveredCanvases.isEmpty)
    }

    @Test("A hole thinner than 40 points or under 5% of the window is none; a tree covering nothing has none")
    func thresholds() {
        let window = CGRect(x: 0, y: 0, width: 2000, height: 700)
        let covered = [
            CGRect(x: 0, y: 0, width: 2000, height: 100),
            // A 500x200 hole at x 100, y 100: about 7% of the window.
            CGRect(x: 0, y: 100, width: 100, height: 200),
            CGRect(x: 600, y: 100, width: 1400, height: 200),
            CGRect(x: 0, y: 300, width: 2000, height: 40),
            // A 200x260 hole at x 1000: thick, but under 5%.
            CGRect(x: 0, y: 340, width: 1000, height: 260),
            CGRect(x: 1200, y: 340, width: 800, height: 260),
            // A full-width strip 36 points tall at y 600: over 5%, but thin.
            CGRect(x: 0, y: 636, width: 2000, height: 64),
        ]
        func areas(_ covered: [CGRect], limit: Int = 16) -> [CGRect] {
            UncoveredAreas.areas(
                in          : window,
                covered     : covered,
                limit       : limit,
                maximumShare: 0.9
            )
        }
        #expect(areas(covered) == [CGRect(x: 104, y: 100, width: 496, height: 200)])
        #expect(areas(covered, limit: 0).isEmpty)
        #expect(areas([]).isEmpty)
    }

    @Test("Cost of the hole search on a 1515x923 window")
    func cost() throws {
        let tree = Self.tree
        var frames: [CGRect] = []
        func collect(_ node: MacTreeNode) {
            for child in node.children {
                if let frame = child.frame?.intersection(Self.window), !frame.isNull, !frame.isEmpty {
                    frames.append(frame)
                }
                collect(child)
            }
        }
        collect(tree)
        let harvest = AccessibilityAugmentation.harvest(
            under      : tree,
            windowFrame: Self.window,
            reader     : CanvasFixtures.Reader()
        )
        let rounds = 200
        let clock = ContinuousClock()
        var found = 0
        let search = clock.measure {
            for _ in 0..<rounds {
                found += UncoveredAreas.areas(
                    in          : Self.window,
                    covered     : frames,
                    limit       : 16,
                    maximumShare: 0.9
                ).count
            }
        }
        #expect(found == 2 * rounds)
        let image = try Self.image()
        var kept = 0
        let pixels = clock.measure {
            for _ in 0..<rounds {
                kept += ScenePipeline.withoutEmptyCanvases(
                    harvest,
                    in         : image,
                    windowWidth: Self.window.width
                ).elements.count { $0.kind == .canvas }
            }
        }
        #expect(kept == rounds)
        print("""
            HOLE_TIMING search: \(search / rounds), pixel check of \(harvest.uncoveredCanvases.count) holes: \
            \(pixels / rounds) per observation; \(frames.count) visible frames of \
            \(harvest.quality.nodesVisited ?? 0) nodes, \(harvest.elements.count) elements
            """)
    }
}
