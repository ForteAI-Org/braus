//
//  CanvasTool.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import CoreGraphics
import Foundation
import IncrementalText
import LocalMCP

/// CanvasTool answers an explicit picture request from retained observations, without advancing
/// the scene or persisting images in the action archive.
enum CanvasTool {

    struct Request: Equatable {
        let id  : String
        let zoom: Int
    }

    static let name = "canvas"

    static var definition: JSONValue {
        .object([
            "name": .string(name),
            "description": .string("Read a [canvas] from the held Seat window's last observation. "
                + "Returns small PNGs: before and after the changed area, or the current whole canvas. "
                + "Observe after an action before requesting its pictures."),
            "inputSchema": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Canvas id printed in the scene, such as canvas 2 or canvas2.")
                    ]),
                    "zoom": .object([
                        "type": .string("integer"),
                        "enum": .array([.number(1), .number(2)]),
                        "default": .number(1)
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            "annotations": .object(["readOnlyHint": .bool(true)])
        ])
    }

    /// Accepts the scene's label and compact or canonical id, with zoom 2 only when explicit.
    static func request(_ arguments: JSONValue) throws -> Request {
        guard let fields = arguments.object, Set(fields.keys).isSubset(of: ["id", "zoom"]),
              let printed = fields["id"]?.string else { throw invalid }
        var text = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("canvas|") { text = String(text.dropFirst(7)) }
        guard text.hasPrefix("canvas") else { throw invalid }
        let number = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard number.first != "0", !number.isEmpty,
              number.utf8.allSatisfy({ (48...57).contains($0) }),
              let ordinal = Int(number), ordinal > 0 else { throw invalid }
        let zoom: Int
        if let value = fields["zoom"] {
            guard case .number(let number) = value, let integer = Int(exactly: number),
                  integer == 1 || integer == 2 else { throw invalid }
            zoom = integer
        } else {
            zoom = 1
        }
        return Request(
            id  : "canvas|canvas\(ordinal)",
            zoom: zoom
        )
    }

    /// Privacy is checked before any image block is formed. The effective zoom, including whole
    /// canvas reduction, is the scale used by the coordinate formula and the caption.
    static func result(
        _ request  : Request,
        history    : CanvasHistory,
        isWithheld : (String) -> Bool,
        withholding: (String) -> String
    ) throws -> JSONValue {
        guard history.window != nil else {
            throw AutomationFailure("No canvas history. Observe the held Seat window first.")
        }
        guard history.contains(request.id) else {
            throw AutomationFailure("Unknown canvas id \(request.id). Use an id from the last observed scene.")
        }
        var answer = try history.crop(
            request.id,
            zoom      : request.zoom,
            isWithheld: isWithheld
        )
        let isPair: Bool
        switch answer {
        case .unchanged, .unavailable:
            isPair = false
            answer = try history.current(
                request.id,
                zoom      : request.zoom,
                isWithheld: isWithheld
            )
        case .crop, .refused:
            isPair = true
        }
        guard case .crop(let crop, let caption) = answer else {
            if answer == .refused {
                throw AutomationFailure("Canvas privacy refusal: the crop touches a secure or withheld field. No pictures returned.")
            }
            throw AutomationFailure("No retained pixels for this canvas. Observe the held Seat window first.")
        }
        let layout = crop.layout
        let rect   = layout.rect
        let zoom   = String(Double(layout.pixelsPerPoint))
        let images = isPair ? [crop.before, crop.after] : [crop.after]
        let claude = isPair ? crop.claudeTokens : crop.claudeTokens / 2
        let gpt    = isPair ? crop.gptTokens : (crop.gptTokens + 1) / 2
        let text = """
        \(request.id): origin \(Int(rect.minX)),\(Int(rect.minY)); size \(Int(rect.width))x\(Int(rect.height)) window points.
        Zoom: \(zoom) pixels per point (requested \(request.zoom)); each PNG \(layout.pixelWidth)x\(layout.pixelHeight) pixels.
        Pictures: \(isPair ? "before, then after the changed area" : "current whole canvas").
        Coordinates: window = origin + point / zoom (top-left origin; point is in picture pixels).
        Caption:
        \(caption)
        Estimated image tokens (\(images.count) pictures): Claude \(claude), GPT \(gpt).
        """
        let content: [JSONValue] = [.object(["type": .string("text"), "text": .string(withholding(text))])]
            + images.map {
                .object([
                    "type": .string("image"),
                    "data": .string($0.base64EncodedString()),
                    "mimeType": .string("image/png")
                ])
            }
        return .object(["content": .array(content), "isError": .bool(false)])
    }

    private static var invalid: AutomationFailure {
        AutomationFailure("canvas needs id from the scene (canvas 2 or canvas2), and optional zoom 1 or 2.")
    }
}
