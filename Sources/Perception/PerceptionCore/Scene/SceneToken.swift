//
//  SceneToken.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// SceneToken is a deterministic, process-stable hash of content, control states and text selection.
///
/// A model echoes it back when it acts, and the actuator compares it against the live scene: the
/// same observed facts yield the same token, including read-only fields past the window edge. It is
/// FNV-1a over a sorted rendering, never Swift's randomized `hashValue`, so two processes and two
/// launches agree.
public struct SceneToken: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Computes the token of a scene from the facts an action depends on.
    public init(
        bundleID: String, windowTitle: String, elements: [SceneElement], outOfViewFields: [OutOfViewField] = []
    ) {
        let body = elements
            .map {
                let body = "\($0.id)|\($0.state?.rawValue ?? "")|\($0.value ?? "")|\($0.isEnabled.map(String.init) ?? "")|\($0.container ?? "")"
                guard let range = SceneElement.validRange($0.selectedRange, value: $0.value) else {
                    return body
                }
                return body + "|selection:\(range.location),\(range.length)"
            }
            .sorted()
            .joined(separator: ";")
        // Read-only values still distinguish observations and must not look like a ghost action.
        // An empty list preserves existing tokens, including persisted scenes.
        let fields = outOfViewFields.map { field in
            [field.label, field.value, field.role, field.isEnabled.map(String.init) ?? "", field.container ?? ""]
                .map { String(reflecting: $0) }.joined(separator: "|")
        }.sorted().joined(separator: ";")
        let facts = fields.isEmpty ? "" : "\noutOfViewFields:" + fields
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(bundleID)\n\(windowTitle)\n\(body)\(facts)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        self.rawValue = String(hash, radix: 16)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
