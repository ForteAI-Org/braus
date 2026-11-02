//
//  CanvasFixturesTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import MacDriver
import PerceptionCore
import Testing

@Suite("Recorded canvas fixture contracts")
struct CanvasFixturesTests {

    @Test("A capture rejects moved, replaced, ambiguous or reordered windows")
    @MainActor
    func captureIdentity() throws {
        let frame = CGRect(
            x     : 10,
            y     : 20,
            width : 1100,
            height: 732
        )
        let window = MacWindowSummary(
            index: 0,
            role : "AXWindow",
            title: "Fixture",
            frame: frame
        )
        let row: [String: Any] = [
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowLayer as String: 0,
            kCGWindowNumber as String: 7,
            kCGWindowBounds as String: frame.dictionaryRepresentation,
        ]
        try CanvasRecordingTests.validateCapture(
            window   : window,
            number   : 7,
            processID: 42,
            windows  : [window],
            rows     : [row]
        )
        var moved = window
        moved.frame = frame.offsetBy(
            dx: 1,
            dy: 0
        )
        var reordered = window
        reordered.index = 1
        for windows in [[moved], [reordered], [window, window], []] {
            #expect(throws: CanvasRecordingTests.RecordingFailure.windowChanged) {
                try CanvasRecordingTests.validateCapture(
                    window   : window,
                    number   : 7,
                    processID: 42,
                    windows  : windows,
                    rows     : [row]
                )
            }
        }
        for key in [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowBounds] {
            var changed = row
            changed.removeValue(forKey: key as String)
            #expect(throws: CanvasRecordingTests.RecordingFailure.windowChanged) {
                try CanvasRecordingTests.validateCapture(
                    window   : window,
                    number   : 7,
                    processID: 42,
                    windows  : [window],
                    rows     : [changed]
                )
            }
        }
        #expect(throws: CanvasRecordingTests.RecordingFailure.windowChanged) {
            try CanvasRecordingTests.validateCapture(
                window   : window,
                number   : 7,
                processID: 42,
                windows  : [window],
                rows     : [row, row]
            )
        }
    }

    @Test("Real recording paths reject checkout descendants before any capture")
    @MainActor
    func recordingPaths() throws {
        let outside = FileManager.default.temporaryDirectory
        #expect(throws: CanvasRecordingTests.RecordingFailure.repositoryDestination) {
            try CanvasRecordingTests.realDestination(
                base: CanvasFixtures.directory,
                work: outside
            )
        }
        #expect(throws: CanvasRecordingTests.RecordingFailure.repositoryDestination) {
            try CanvasRecordingTests.realDestination(
                base: outside,
                work: CanvasFixtures.directory
            )
        }
        let destination = try CanvasRecordingTests.realDestination(
            base: outside,
            work: outside
        )
        #expect(destination.deletingLastPathComponent() == outside)
    }

    @Test("The complete fixture set stays below 1.5 MB")
    func recordingSize() throws {
        let files = try #require(
            FileManager.default.enumerator(
                at                        : CanvasFixtures.directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )
        )
        var bytes = 0
        for case let url as URL in files where ["png", "json"].contains(url.pathExtension) {
            bytes += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        #expect(bytes > 0 && bytes < 1_500_000)
    }

    @Test(
        "Every recording loads as an AX snapshot and a 1x window image",
        arguments: CanvasFixtures.variants
    )
    func loads(variant: String) throws {
        let recording = try CanvasFixtures.load(variant)
        let frame = try #require(recording.tree.frame)
        #expect(recording.tree.role == "AXWindow")
        #expect(!recording.tree.hasUnreadParts)
        #expect(recording.image.width == Int(frame.width))
        #expect(recording.image.height == Int(frame.height))
    }

    @Test("Canvases have frames and no readable text or children; native controls remain readable")
    func accessibility() throws {
        let tree = try CanvasFixtures.load("still").tree
        for identifier in ["canvas.timeline", "canvas.image", "canvas.empty"] {
            let node = try #require(tree.flattened.first { $0.identifier == identifier })
            #expect(node.frame?.isEmpty == false)
            #expect(["AXGroup", "AXImage"].contains(node.role))
            #expect(node.children.isEmpty)
            #expect(node.unread == nil)
            let text = [node.title, node.descriptionText, node.value].compactMap { $0 }
            #expect(text.allSatisfy { $0.isEmpty })
        }
        let frame = try #require(tree.frame)
        let harvest = AccessibilityAugmentation.harvest(
            under      : tree,
            windowFrame: frame,
            reader     : CanvasFixtures.Reader()
        )
        #expect(harvest.quality.walkCompleted == true)
        let labels = Set(harvest.elements.map(\.label))
        for label in ["Play", "Search", "Zoom"] + (1...4).map({ "Track \($0)" })
            + stride(
                from   : 0,
                through: 30,
                by     : 5
            ).map({
                String(
                    format: "00:%02d",
                    $0
                )
            })
        {
            #expect(
                labels.contains(label),
                "Missing readable label: \(label)"
            )
        }
        for (
            label,
            role
        ) in [("Play", "AXButton"), ("Search", "AXTextField"), ("Zoom", "AXPopUpButton")] {
            #expect(
                tree.flattened.contains {
                    $0.role == role && [$0.title, $0.descriptionText, $0.value].compactMap { $0 }.contains(label)
                }
            )
        }
        let staticLabels =
            (1...4).map { "Track \($0)" }
            + stride(
                from   : 0,
                through: 30,
                by     : 5
            ).map {
                String(
                    format: "00:%02d",
                    $0
                )
            }
        for label in staticLabels {
            #expect(tree.flattened.contains { $0.role == "AXStaticText" && $0.value == label })
        }
        #expect(!tree.flattened.contains { ($0.value ?? "").contains("Clip") })
    }

    @Test("Idle phases change pixels only within the level meter")
    func meterChanges() throws {
        let baseline = try CanvasFixtures.load("still")
        let timeline = try #require(baseline.tree.flattened.first { $0.identifier == "canvas.timeline" }?.frame)
        let meter = CGRect(
            x     : timeline.maxX - 78,
            y     : timeline.minY + 8,
            width : 68,
            height: 48
        )
        var distinct = Set<Data>()
        for index in 0..<6 {
            let phase = try CanvasFixtures.load("meter-phases/\(index)")
            #expect(phase.tree == baseline.tree)
            let pixels = try rgba(phase.image)
            distinct.insert(Data(pixels))
            try expectChanges(
                from   : baseline,
                to     : phase,
                within : meter,
                changes: index != 0
            )
        }
        #expect(distinct.count == 6)
    }

    @Test("Moving lane 2's clip changes only that lane")
    func clipChanges() throws {
        let baseline = try CanvasFixtures.load("still")
        let moved = try CanvasFixtures.load("clip-moved")
        let timeline = try #require(baseline.tree.flattened.first { $0.identifier == "canvas.timeline" }?.frame)
        #expect(moved.tree == baseline.tree)
        try expectChanges(
            from  : baseline,
            to    : moved,
            within: CGRect(
                x     : timeline.minX,
                y     : timeline.minY + 80,
                width : timeline.width,
                height: 80
            ),
            changes: true
        )
    }

    @Test("The empty negative region is uniform while both canvases contain detail")
    func negativePixels() throws {
        let recording = try CanvasFixtures.load("still")
        let window = try #require(recording.tree.frame)
        let pixels = try rgba(recording.image)
        for identifier in ["canvas.timeline", "canvas.image", "canvas.empty"] {
            let frame = try #require(recording.tree.flattened.first { $0.identifier == identifier }?.frame)
                .offsetBy(
                    dx: -window.minX,
                    dy: -window.minY
                ).insetBy(
                    dx: 2,
                    dy: 2
                )
            var colours = Set<UInt32>()
            for y in Int(frame.minY)..<Int(frame.maxY) {
                for x in Int(frame.minX)..<Int(frame.maxX) {
                    let offset = (y * recording.image.width + x) * 4
                    colours.insert(pixels[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) })
                }
            }
            #expect(identifier == "canvas.empty" ? colours.count == 1 : colours.count > 50)
        }
    }

    /// Normalizes every PNG to top-left RGBA, including alpha in the exact comparisons.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data            : buffer.baseAddress,
                    width           : image.width,
                    height          : image.height,
                    bitsPerComponent: 8,
                    bytesPerRow     : image.width * 4,
                    space           : CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(
                image,
                in: CGRect(
                    x     : 0,
                    y     : 0,
                    width : image.width,
                    height: image.height
                )
            )
        }
        return bytes
    }

    private func expectChanges(
        from baseline: CanvasFixtures.Recording,
        to changed: CanvasFixtures.Recording,
        within frame: CGRect,
        changes: Bool
    ) throws {
        #expect(changed.image.width == baseline.image.width && changed.image.height == baseline.image.height)
        let window = try #require(baseline.tree.frame)
        let allowed = frame.offsetBy(
            dx: -window.minX,
            dy: -window.minY
        )
        let before = try rgba(baseline.image)
        let after = try rgba(changed.image)
        var inside = 0
        var outside = 0
        for y in 0..<baseline.image.height {
            for x in 0..<baseline.image.width {
                let offset = (y * baseline.image.width + x) * 4
                guard
                    before[offset] != after[offset] || before[offset + 1] != after[offset + 1]
                        || before[offset + 2] != after[offset + 2] || before[offset + 3] != after[offset + 3]
                else { continue }
                if allowed.contains(
                    CGPoint(
                        x: x,
                        y: y
                    )
                ) {
                    inside += 1
                } else {
                    outside += 1
                }
            }
        }
        #expect(
            outside == 0,
            "Changed pixels outside the allowed region: \(outside)"
        )
        #expect(changes ? inside > 0 : inside == 0)
    }
}
