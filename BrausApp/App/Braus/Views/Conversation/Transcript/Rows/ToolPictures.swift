//
//  ToolPictures.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import Foundation
import ImageIO
import LocalMCP
import UniformTypeIdentifiers

/// ToolPictures is what a tool result showed the model as pictures (a `canvas` crop pair, a
/// `human_step` picture), kept with the turn's tool records so its tool line can show them, also
/// after the conversation is opened again.
///
/// The host reads them from the result's MCP image blocks (`record(tool:result:)`) and writes them
/// as one record after the tool's own, `▧ name {json}`, which `ToolStep.steps` puts on the tool's
/// latest step. A record keeps at most `pictureLimit` pictures, each at most `byteLimit` bytes: a
/// larger one is stored as JPEG, its long edge `reducedEdge` pixels or a half or a quarter of that,
/// the first that fits, so a stored conversation stays small. Its
/// label is one line of the result's text: the line after `Caption:` when the text has one, else
/// its first line. The label is text and goes through withholding like any record; the pictures
/// are not text and never do (`withholdingLabel`).
nonisolated struct ToolPictures: Sendable, Hashable, Codable {

    /// One picture as the tool gave it, or reduced, with its size in pixels.
    struct Picture: Sendable, Hashable, Codable {
        let data  : Data
        let width : Int
        let height: Int
    }

    let label   : String?
    let pictures: [Picture]

    /// The mark a pictures record starts with.
    static let mark = "▧ "

    static let pictureLimit = 2
    static let byteLimit    = 200_000
    static let reducedEdge  = 1024
    static let labelLimit   = 120

    /// The pictures records one turn keeps; later ones in the same turn are not stored.
    static let recordsPerTurn = 4

    /// The record of `tool`'s `result` when it carries an image block, nil otherwise or for an error.
    static func record(
        tool  : String,
        result: JSONValue
    ) -> String? {
        let blocks = result["content"].array ?? []
        guard result["isError"].bool != true else { return nil }

        let pictures = Array(blocks.lazy
            .filter { $0["type"].string == "image" }
            .compactMap { $0["data"].string.flatMap { Data(base64Encoded: $0) } }
            .compactMap(stored)
            .prefix(pictureLimit))
        guard !pictures.isEmpty else { return nil }

        let text = blocks.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined(separator: "\n")
        return ToolPictures(label: label(of: text), pictures: pictures).record(tool: tool)
    }

    /// The tool's name and its pictures, when `line` is a pictures record this build can read.
    static func read(_ line: String) -> (tool: String, pictures: ToolPictures)? {
        guard line.hasPrefix(mark) else { return nil }
        let body = line.dropFirst(mark.count)
        let tool = String(body.prefix { $0 != " " })
        let json = body.dropFirst(tool.count).drop { $0 == " " }
        do {
            return (tool, try JSONDecoder().decode(ToolPictures.self, from: Data(json.utf8)))
        } catch {
            return nil
        }
    }

    /// The record with `withhold` applied to its label only: the pictures are binary, and a
    /// text rule run over their encoding could match a secret inside it and destroy it.
    static func withholdingLabel(
        _ line  : String,
        withhold: (String) -> String
    ) -> String? {
        guard let read = read(line) else { return nil }
        return ToolPictures(
            label   : read.pictures.label.map(withhold),
            pictures: read.pictures.pictures
        ).record(tool: read.tool)
    }

    /// This value as the record of `tool`.
    func record(tool: String) -> String? {
        let encoder = JSONEncoder()
        // Base64 holds slashes, which escaped would grow every stored picture; sorted keys keep a record stable.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let json = try? encoder.encode(self) else { return nil }
        return Self.mark + tool + " " + String(decoding: json, as: UTF8.self)
    }

    // MARK: Reading a result

    /// The picture as stored: as given when small enough, else reduced to JPEG; nil when it is no image.
    private static func stored(_ data: Data) -> Picture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width  = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        guard data.count > byteLimit else { return Picture(data: data, width: width, height: height) }

        for edge in [reducedEdge, reducedEdge / 2, reducedEdge / 4] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize         : edge,
                kCGImageSourceCreateThumbnailWithTransform  : true,
            ]
            let reduced = NSMutableData()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let file  = CGImageDestinationCreateWithData(reduced, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(file, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(file) else { return nil }
            if reduced.length <= byteLimit { return Picture(data: reduced as Data, width: image.width, height: image.height) }
        }
        return nil
    }

    /// The line after `Caption:`, on it or on the next line with words, else the text's first line.
    static func label(of text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var chosen = lines.first
        if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix("caption:") }) {
            let rest = lines[index].dropFirst("caption:".count).trimmingCharacters(in: .whitespaces)
            chosen = rest.isEmpty ? lines.dropFirst(index + 1).first : rest
        }
        return chosen.map { $0.count > labelLimit ? $0.prefix(labelLimit - 1) + "…" : $0 }
    }
}
