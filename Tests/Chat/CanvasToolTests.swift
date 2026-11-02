//
//  CanvasToolTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

@testable import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import ImageIO
import IncrementalText
import LocalMCP
import PerceptionCore
import Testing

@Suite
@MainActor
struct CanvasToolTests {

    @Test(arguments: ["canvas 2", "canvas2", "canvas|canvas2", " canvas 2 "])
    func parsesPrintedIDs(_ id: String) throws {
        let request = try CanvasTool.request(.object(["id": .string(id)]))
        #expect(request.id == "canvas|canvas2")
        #expect(request.zoom == 1)
        #expect(try CanvasTool.request(.object([
            "id": .string(id), "zoom": .number(2)
        ])).zoom == 2)
    }

    @Test(arguments: [
        JSONValue.null, .object([:]), .object(["id": .number(2)]),
        .object(["id": .string("canvas 0")]), .object(["id": .string("canvas02")]),
        .object(["id": .string("canvas-2")]), .object(["id": .string("canvas2x")]),
        .object(["id": .string("canvas999999999999999999999")]),
        .object(["id": .string("canvas2"), "zoom": .number(0)]),
        .object(["id": .string("canvas2"), "zoom": .number(3)]),
        .object(["id": .string("canvas2"), "zoom": .number(1.5)]),
        .object(["id": .string("canvas2"), "zoom": .bool(true)]),
        .object(["id": .string("canvas2"), "zoom": .string("2")]),
        .object(["id": .string("canvas2"), "extra": .bool(true)])
    ])
    func rejectsInvalidArguments(_ arguments: JSONValue) {
        #expect(throws: AutomationFailure.self) { try CanvasTool.request(arguments) }
    }

    @Test
    func routerReturnsTextAndTwoPNGsWithoutObservingOrArchiving() async throws {
        let session = CanvasSession()
        session.canvasHistory = try history()
        let tools = AutomationTools(session: session)
        var records: [String] = []
        tools.record = { records.append($0) }
        let router = MCPRouter(
            tools: tools.toolDefinitions,
            call: tools.call
        )
        #expect(tools.toolDefinitions.contains { $0["name"].string == "canvas" })
        #expect(AutomationTools.interruptionPolicy(for: "canvas") == .readOnly)
        let response = try #require(await router.handle(request()))
        let result = response["result"]
        #expect(result["isError"] == .bool(false))
        let blocks = try #require(result["content"].array)
        #expect(blocks.count == 3)
        #expect(blocks[0]["type"] == .string("text"))
        let text = try #require(blocks[0]["text"].string)
        for part in ["origin", "window points", "Zoom: 1.0", "before, then after", "Caption:",
                     "window = origin + point / zoom", "Estimated image tokens", "Claude", "GPT"] {
            #expect(text.contains(part))
        }
        let before = try image(blocks[1])
        let after = try image(blocks[2])
        #expect(before.width == after.width && before.height == after.height)
        #expect(blocks[1]["data"] != blocks[2]["data"])
        #expect(session.observations == 0)
        #expect(records.isEmpty)
    }

    @Test
    func zoomTwoDoublesChangedCropPixels() async throws {
        let session = CanvasSession()
        session.canvasHistory = try history()
        let tools = AutomationTools(session: session)
        let one = try await tools.call(
            "canvas",
            .object(["id": .string("canvas2")])
        )
        let two = try await tools.call(
            "canvas",
            .object(["id": .string("canvas 2"), "zoom": .number(2)])
        )
        let small = try image(try #require(one["content"].array?[1]))
        let large = try image(try #require(two["content"].array?[1]))
        #expect(large.width == 2 * small.width)
        #expect(large.height == 2 * small.height)
        #expect(two["content"].array?.first?["text"].string?.contains("Zoom: 2.0") == true)
    }

    @Test
    func unchangedReturnsOneWholeCanvasReducedTo1280Pixels() async throws {
        let session = CanvasSession()
        session.canvasHistory = try history(
            changed: false,
            width  : 2000
        )
        let tools = AutomationTools(session: session)
        let result = try await tools.call(
            "canvas",
            .object(["id": .string("canvas2"), "zoom": .number(2)])
        )
        let blocks = try #require(result["content"].array)
        #expect(blocks.count == 2)
        let png = try image(blocks[1])
        #expect(png.width == 1280)
        let text = try #require(blocks[0]["text"].string)
        #expect(text.contains("current whole canvas"))
        #expect(text.contains("Zoom: 0.8"))
        #expect(text.contains("size 1600x240 window points"))
    }

    @Test
    func firstObservationCanSupplyCurrentCanvas() async throws {
        let session = CanvasSession()
        session.canvasHistory = try history(firstOnly: true)
        let result = try await AutomationTools(session: session).call(
            "canvas",
            .object(["id": .string("canvas2")])
        )
        #expect(result["content"].array?.count == 2)
        #expect(result["content"].array?.first?["text"].string?.contains("current whole canvas") == true)
    }

    @Test(arguments: ["no held window", "no history", "unknown id", "secure before", "secure after",
                      "secure unchanged", "withheld field"])
    func refusalsAreToolErrorsWithoutImages(_ scenario: String) async throws {
        let session = CanvasSession()
        session.canvasHistory = try history(
            changed     : scenario != "secure unchanged",
            secureBefore: scenario == "secure before",
            secureAfter : scenario == "secure after" || scenario == "secure unchanged",
            withheld    : scenario == "withheld field"
        )
        if scenario == "no held window" { session.id = nil }
        if scenario == "no history" { session.canvasHistory = CanvasHistory() }
        let tools = AutomationTools(session: session)
        let router = MCPRouter(
            tools: tools.toolDefinitions,
            call: tools.call
        )
        let response = try #require(await router.handle(request(id: scenario == "unknown id" ? "canvas9" : "canvas2")))
        #expect(response["result"]["isError"] == .bool(true))
        let blocks = try #require(response["result"]["content"].array)
        #expect(blocks.count == 1)
        let text = try #require(blocks[0]["text"].string)
        #expect(!text.isEmpty)
        if scenario.hasPrefix("secure") || scenario == "withheld field" {
            #expect(text.contains("privacy refusal"))
        }
    }

    private func request(id: String = "canvas 2") -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("canvas"), "arguments": .object(["id": .string(id)])])
        ])
    }

    private func image(_ block: JSONValue) throws -> CGImage {
        #expect(block["type"] == .string("image"))
        #expect(block["mimeType"] == .string("image/png"))
        let data = try #require(block["data"].string.flatMap { Data(base64Encoded: $0) })
        let source = try #require(CGImageSourceCreateWithData(
            data as CFData,
            nil
        ))
        return try #require(CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ))
    }

    /// Two synthetic observations with an input between them keep tile noise from hiding the move.
    private func history(
        changed     : Bool = true,
        width       : Int = 800,
        firstOnly   : Bool = false,
        secureBefore: Bool = false,
        secureAfter : Bool = false,
        withheld    : Bool = false
    ) throws -> CanvasHistory {
        var history = CanvasHistory()
        for index in 0..<(firstOnly ? 1 : 2) {
            let context = try #require(CGContext(
                data            : nil,
                width           : width,
                height          : 400,
                bitsPerComponent: 8,
                bytesPerRow     : 0,
                space           : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(
                gray : 0.2,
                alpha: 1
            )
            context.fill(CGRect(
                x: 0,
                y: 0,
                width: width,
                height: 400
            ))
            if index == 1 && changed {
                context.setFillColor(
                    gray : 0.8,
                    alpha: 1
                )
                context.fill(CGRect(
                    x: 200,
                    y: 180,
                    width: 40,
                    height: 40
                ))
            }
            let canvas = SceneElement(
                id    : "canvas|canvas2",
                kind  : .canvas,
                label : "canvas 2",
                bounds: NormalizedRect(
                    x: 0.1,
                    y: 0.2,
                    width: 0.8,
                    height: 0.6
                )
            )
            var scene = SceneSnapshot(
                bundleID         : "com.braus.fixture.canvas",
                appName          : "CanvasFixture",
                windowTitle      : "Canvas fixture",
                viewportPixelSize: ViewportPixelSize(
                    width: width,
                    height: 400
                ),
                elements         : [canvas]
            )
            if (index == 0 && secureBefore) || (index == 1 && secureAfter) || withheld {
                scene.elements.append(SceneElement(
                    id    : "control|pin",
                    kind  : .control,
                    label : withheld ? "Password" : "Entry",
                    bounds: NormalizedRect(
                        x: 0.25,
                        y: 0.45,
                        width: 0.05,
                        height: 0.1
                    ),
                    role  : withheld ? "AXTextField" : "AXSecureTextField"
                ))
            }
            history.observe(
                &scene,
                in           : try #require(context.makeImage()),
                window       : 7,
                windowSize   : CGSize(
                    width: width,
                    height: 400
                ),
                displayedAt  : index == 0 ? 10 : 30,
                lastCommandAt: index == 0 ? nil : 20
            )
        }
        return history
    }
}

@MainActor
private final class CanvasSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    var canvasHistory: CanvasHistory?
    var observations = 0

    func open(
        application: String,
        window     : String?
    ) async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func observe() async throws -> SceneSnapshot {
        observations += 1
        throw AutomationFailure("unused")
    }
    func act(
        target      : String,
        verb        : ActionVerb,
        section     : String?,
        desiredState: ControlState?
    ) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(
        control: String,
        item   : String
    ) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(
        _ input: InputRequest.Input,
        section: String?
    ) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func close() async {}
}
