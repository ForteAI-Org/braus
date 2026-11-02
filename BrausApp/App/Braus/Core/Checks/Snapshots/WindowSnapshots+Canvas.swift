//
//  WindowSnapshots+Canvas.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit
import ImageIO
import LocalMCP
import UniformTypeIdentifiers

extension WindowSnapshots {

    /// True while a snapshot draws a tool line's pictures enlarged (`ToolPicturesView`).
    static var opensToolPictures = false

    /// Atlas's turn looked at a timeline canvas: its tool line with the before and after under it,
    /// then the same pictures enlarged. The records are the ones a real turn stores, made from a tool
    /// result with two image blocks (`ToolPictures.record`). Offscreen, the overlay's dimmed backdrop,
    /// a bare layer, is not drawn.
    static func writeCanvasPictures(
        in store : URL,
        to output: URL
    ) async throws {
        let result: JSONValue = .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Canvas 2 changed: before and after of 40,8 360x72 at zoom 1.\n"
                        + "Caption: Timeline · Lane 2, 00:04 to 00:12"),
                ]),
                image(clipAt: 72),
                image(clipAt: 196),
            ]),
            "isError": .bool(false),
        ])
        guard let pictures = ToolPictures.record(tool: "canvas", result: result) else {
            throw CanvasSnapshotFailure("no pictures record")
        }
        let team = try await syntheticTeam(
            in   : store.appending(
                path         : "Canvas",
                directoryHint: .isDirectory
            ),
            tools: [
                "→ open_session {\"app\":\"Canvas Fixture\"}",
                "← open_session {\"session\":\"s\"}",
                "→ drag {\"session\":\"s\",\"from\":\"Clip 2\",\"to\":\"00:08\"}",
                "← drag {\"status\":\"found_acted\"}",
                "→ canvas {\"session\":\"s\",\"id\":\"canvas 2\"}",
                "← canvas {\"zoom\":1}",
                pictures,
            ]
        )
        try await writeHouseWindow(
            team,
            width    : 1200,
            inspector: false,
            to       : output.appending(path: "house-canvas-pictures.png")
        )
        opensToolPictures = true
        defer { opensToolPictures = false }
        try await writeHouseWindow(
            team,
            width    : 1200,
            inspector: false,
            to       : output.appending(path: "house-canvas-pictures-enlarged.png")
        )
    }

    /// An MCP image block of a 360 by 72 pixel timeline lane with one clip starting at `clip`.
    private static func image(clipAt clip: CGFloat) -> JSONValue {
        let size = CGSize(width: 360, height: 72)
        guard let context = CGContext(
            data            : nil,
            width           : Int(size.width),
            height          : Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .null }

        context.setFillColor(gray: 0.12, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(gray: 0.2, alpha: 1)
        for tick in stride(from: CGFloat(0), to: size.width, by: 30) {
            context.fill(CGRect(x: tick, y: 0, width: 1, height: size.height))
        }
        context.setFillColor(red: 0.36, green: 0.52, blue: 0.78, alpha: 1)
        context.fill(CGRect(x: clip, y: 18, width: 96, height: 36))
        guard let image = context.makeImage() else { return .null }

        let data = NSMutableData()
        guard let file = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return .null
        }
        CGImageDestinationAddImage(file, image, nil)
        guard CGImageDestinationFinalize(file) else { return .null }
        return .object([
            "type"    : .string("image"),
            "data"    : .string((data as Data).base64EncodedString()),
            "mimeType": .string("image/png"),
        ])
    }

    private struct CanvasSnapshotFailure: Error, CustomStringConvertible {

        let description: String

        init(_ description: String) { self.description = description }
    }
}
