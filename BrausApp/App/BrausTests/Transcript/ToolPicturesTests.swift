//
//  ToolPicturesTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit
import ChatCore
import Foundation
import ImageIO
import LocalMCP
import Memory
import ModelTransports
import Testing
import UniformTypeIdentifiers
@testable import Braus

/// The pictures a tool result showed the model: read from its MCP image blocks and stored with the
/// turn's tool records, on the step of the tool that showed them.
@Suite("Tool pictures: read from a result and recorded with the turn")
struct ToolPicturesTests {

    /// A PNG of `width` by `height` pixels, a flat grey with one lighter column so two differ.
    static func png(width: Int, height: Int, mark: Int = 0) throws -> Data {
        let context = try #require(CGContext(
            data            : nil,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.8, alpha: 1)
        context.fill(CGRect(x: mark % max(1, width), y: 0, width: 4, height: height))
        let image = try #require(context.makeImage())
        let data  = NSMutableData()
        let file  = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(file, image, nil)
        #expect(CGImageDestinationFinalize(file))
        return data as Data
    }

    /// A tool result as `canvas` and `human_step` answer: a text block, then image blocks.
    static func result(_ text: String, images: [Data], isError: Bool = false) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])] + images.map {
                .object([
                    "type"    : .string("image"),
                    "data"    : .string($0.base64EncodedString()),
                    "mimeType": .string("image/png"),
                ])
            }),
            "isError": .bool(isError),
        ])
    }

    static let canvasText = "Canvas 2 changed: before and after of 120,40 160x60 at zoom 1.\nCaption: Timeline · lane 2\n"
        + "Window point = origin + point / zoom."

    static func canvasLines(before: Data, after: Data) throws -> [String] {
        [
            #"→ canvas {"session":"s","id":"canvas 2"}"#,
            #"← canvas {"zoom":1}"#,
            try #require(ToolPictures.record(tool: "canvas", result: result(canvasText, images: [before, after]))),
        ]
    }

    // MARK: Reading a result

    @Test("A result's image blocks become one record with their pixel sizes and the caption line as label")
    func recordsImageBlocks() throws {
        let before = try Self.png(width: 160, height: 60)
        let after  = try Self.png(width: 160, height: 60, mark: 80)
        let line   = try #require(ToolPictures.record(tool: "canvas", result: Self.result(Self.canvasText,
                                                                                         images: [before, after])))
        #expect(line.hasPrefix("▧ canvas {"))
        #expect(!line.contains(#"\/"#), "base64 slashes are not escaped")

        let read = try #require(ToolPictures.read(line))
        #expect(read.tool == "canvas")
        #expect(read.pictures.label == "Timeline · lane 2")
        #expect(read.pictures.pictures.map(\.data) == [before, after])
        #expect(read.pictures.pictures.map(\.width) == [160, 160])
        #expect(read.pictures.pictures.map(\.height) == [60, 60])
    }

    @Test("No image, an error, or more pictures than a record keeps: nothing, nothing, the first two")
    func limits() throws {
        let png = try Self.png(width: 20, height: 10)
        #expect(ToolPictures.record(tool: "observe", result: Self.result("scene", images: [])) == nil)
        #expect(ToolPictures.record(tool: "canvas", result: Self.result("No history.", images: [png],
                                                                        isError: true)) == nil)
        let three = try #require(ToolPictures.record(tool: "canvas", result: Self.result("x", images: [png, png, png])))
        #expect(ToolPictures.read(three)?.pictures.pictures.count == ToolPictures.pictureLimit)
        #expect(ToolPictures.label(of: "First line\nsecond") == "First line")
        #expect(ToolPictures.label(of: "Caption:\n\n  Ruler 00:10  \nmore") == "Ruler 00:10")
        #expect(ToolPictures.label(of: "") == nil)
    }

    @Test("A picture over the byte limit is stored reduced, within the limit and the reduced edge")
    func reducesLargePictures() throws {
        // Noise does not compress, so this PNG is far over the limit.
        let side    = 1600
        var bytes   = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 7
        for index in bytes.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let image = try bytes.withUnsafeMutableBytes { buffer in
            try #require(CGContext(
                data            : buffer.baseAddress,
                width           : side,
                height          : side,
                bitsPerComponent: 8,
                bytesPerRow     : side * 4,
                space           : CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo      : CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage())
        }
        let data = NSMutableData()
        let file = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(file, image, nil)
        #expect(CGImageDestinationFinalize(file))
        #expect(data.length > ToolPictures.byteLimit)

        let line    = try #require(ToolPictures.record(tool: "human_step", result: Self.result("Step 3", images: [data as Data])))
        let picture = try #require(ToolPictures.read(line)?.pictures.pictures.first)
        #expect(picture.data.count <= ToolPictures.byteLimit)
        #expect(max(picture.width, picture.height) <= ToolPictures.reducedEdge)
        #expect(NSImage(data: picture.data) != nil)
    }

    @Test("Withholding touches the label only: a secret found inside the encoding would destroy it")
    func withholdingKeepsPictures() throws {
        let png  = try Self.png(width: 64, height: 64)
        let line = try #require(ToolPictures.record(tool: "canvas", result: Self.result("Caption: Password hunter2",
                                                                                        images: [png])))
        // Eight characters of the encoding stand for a secret that happens to occur in it.
        let inside = String(png.base64EncodedString().dropFirst(40).prefix(8))
        let rule   = ValueMinimization(secrets: ["hunter2", inside])
        #expect(ToolPictures.read(rule.minimize(text: line).0) == nil, "the rule over the whole record destroys it")

        let kept = try #require(ToolPictures.withholdingLabel(line) { rule.minimize(text: $0).0 })
        let read = try #require(ToolPictures.read(kept))
        #expect(read.pictures.pictures.first?.data == png)
        #expect(read.pictures.label?.contains("hunter2") == false)
    }

    // MARK: The tool line

    @Test("Pictures go on their tool's latest step; a tool without a call gets a step; a bad record shows nothing")
    func stepsCarryPictures() throws {
        let before = try Self.png(width: 160, height: 60)
        let after  = try Self.png(width: 160, height: 60, mark: 40)
        let step   = try #require(ToolPictures.record(tool: "human_step", result: Self.result("Step 3: clicked Play",
                                                                                              images: [after])))
        let lines  = try Self.canvasLines(before: before, after: after) + [step, "▧ canvas {not json"]
        let steps  = ToolStep.steps(from: lines)

        #expect(steps.map(\.action) == [.canvas(id: "canvas 2"), .humanStep])
        #expect(steps[0].pictures?.pictures.map(\.data) == [before, after])
        #expect(steps[1].pictures?.label == "Step 3: clicked Play")
        #expect(TranscriptWording.toolSteps(steps, ending: .completed) == ["Looked at canvas 2", "Viewed what you did"])
        #expect(!steps.contains { $0.isEffectful })
        let copied = ToolStep.copyText(of: lines, isExpanded: false, ending: .completed, detailed: true)
        #expect(copied.contains("▧ canvas 2 pictures") && copied.count < 600, "a detailed copy names the pictures")
    }

    // MARK: Stored

    @Test("Recorded through a turn with withholding and capped per turn, the pictures read back whole")
    @MainActor
    func persisted() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.store.configure(
            worker   : fixture.workerID,
            selection: ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low)
        )
        let asked  = try await fixture.store.appendMessage(to: fixture.conversation, text: "Move the clip on lane 2.")
        let before = try Self.png(width: 160, height: 60)
        let after  = try Self.png(width: 160, height: 60, mark: 100)
        let rule   = ValueMinimization(secrets: [])
        let recorder = WorkerTurnRecorder(
            store         : fixture.store,
            workspaceID   : TranscriptFixture.workspaceID,
            workerID      : fixture.workerID,
            conversationID: fixture.conversation,
            messageID     : asked.id,
            withholding   : { rule.minimize(text: $0).0 }
        ) {}
        let lines = try Self.canvasLines(before: before, after: after)
        _ = try await recorder.run { _, _, emit in
            // One canvas call more than a turn keeps the pictures of.
            for _ in 0...ToolPictures.recordsPerTurn {
                for line in lines { emit(.tool(line)) }
            }
            emit(.provider(.assistant("The clip moved right.")))
            emit(.provider(.completed))
        }
        let stored = try await fixture.store.events(matching: EventQuery(scope: .conversation(fixture.conversation)))
            .compactMap(WorkerTurnRecorder.text(of:))
        #expect(stored.filter { $0.hasPrefix(ToolPictures.mark) }.count == ToolPictures.recordsPerTurn)
        #expect(stored.prefix(3) == ArraySlice(lines))

        let steps = ToolStep.steps(from: stored)
        #expect(steps.compactMap(\.pictures).count == ToolPictures.recordsPerTurn)
        #expect(steps.first?.pictures?.pictures.map(\.data) == [before, after])
    }
}
