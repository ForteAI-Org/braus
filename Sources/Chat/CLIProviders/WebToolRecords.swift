//
//  WebToolRecords.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation

/// WebToolRecords writes a command line's own web searches and page reads
/// as the tool records `AutomationTools.record` writes, so the tool line
/// reads them like any other step: the call `→ web_search {"query":…}` or
/// `→ web_fetch {"url":…}`, then `← name done` or `← name error: …`.
///
/// A call is written as it starts when the provider already says what it
/// searches or reads (Claude Code), and otherwise as it finishes, just
/// before its result, since Codex names its query only then. One value
/// reads one turn.
///
/// What a call searches or reads goes through `withholding` before it is
/// encoded, so a text JSON escapes is found as written: the host passes
/// what its tools' records withhold (`AutomationTools.withheld`), and a
/// secret the agent put in a query or an address is not written (M07),
/// percent-encoded in an address too (`withheld(_:by:)`).
public nonisolated struct WebToolRecords {

    /// The calls written as they started, by id, waiting for their result.
    private var announced: Set<String> = []

    public init() {}

    /// The records `event` adds, in order; none for an event that is not web activity.
    public mutating func lines(for event: ProviderEvent, withholding: (String) -> String) throws -> [String] {
        guard case .web(let id, let kind, let detail, let phase) = event else { return [] }

        let name      = kind == .search ? "web_search" : "web_fetch"
        let arguments = detail.map { [kind == .search ? "query" : "url": Self.withheld($0, by: withholding)] } ?? [:]
        let encoder   = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let call      = "→ \(name) \(String(decoding: try encoder.encode(arguments), as: UTF8.self))"

        switch phase {
        case .started:
            guard detail != nil else { return [] }
            if let id { announced.insert(id) }
            return [call]
        case .finished(let failed):
            let result = failed ? "← \(name) error: The web tool reported a failure." : "← \(name) done"
            if let id, announced.remove(id) != nil { return [result] }
            return [call, result]
        }
    }

    /// `detail` through `withholding` as written, then as an address decodes it: a secret an address carries
    /// percent-encoded (a quote as `%22`, a space as `%20` or, in a query's form encoding, `+`) is not found as
    /// written. Each decoding whose text has something withheld is written decoded, with it withheld; a detail with
    /// nothing withheld in any form is written as it came, so an ordinary address keeps its encoding.
    static func withheld(_ detail: String, by withholding: (String) -> String) -> String {
        var kept = withholding(detail)
        for plusIsSpace in [false, true] {
            let decoded = Self.decoded(kept, plusIsSpace: plusIsSpace)
            let withheld = withholding(decoded)
            if withheld != decoded { kept = withheld }
        }
        return kept
    }

    /// `text` with each `%` and two hex digits decoded as a UTF-8 byte, and with `plusIsSpace` each `+` as a space;
    /// a `%` without two hex digits after it stays as it is.
    static func decoded(_ text: String, plusIsSpace: Bool) -> String {
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x37
            case 0x61...0x66: byte - 0x57
            default:          nil
            }
        }
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
               let high = hex(utf8[index + 1]), let low = hex(utf8[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(plusIsSpace && utf8[index] == UInt8(ascii: "+") ? UInt8(ascii: " ") : utf8[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
