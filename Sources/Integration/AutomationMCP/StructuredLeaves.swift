//
//  StructuredLeaves.swift
//  Braus
//

import Foundation
import LocalMCP
import Memory

/// StructuredLeaves turns an adapter's JSON object into the leaves the record keeps of it (P2-02): one
/// `StructuredField` per string, number, boolean or null, named by its JSON pointer (RFC 6901, `~` and `/` escaped), in
/// pointer order, at most `StructuredField.maximumLeaves`. A number keeps the text JSON writes for it; an empty array or
/// object has no leaf. What the record withholds of them is the call's minimization's to decide.
enum StructuredLeaves {

    static func fields(of value: JSONValue) -> [StructuredField] {
        var leaves: [StructuredField] = []
        func walk(_ value: JSONValue, _ path: String) {
            guard leaves.count < StructuredField.maximumLeaves else { return }
            let pointer = path.isEmpty ? "/" : path
            switch value {
                case .object(let fields):
                    for (key, field) in fields.sorted(by: { $0.key < $1.key }) { walk(field, path + "/" + escape(key)) }
                case .array(let items):
                    for (index, item) in items.enumerated() { walk(item, path + "/\(index)") }
                case .string(let text):
                    if let leaf = try? StructuredField(path: pointer, kind: .text, text: text) { leaves.append(leaf) }
                case .number(let number):
                    let text = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
                    if let leaf = try? StructuredField(path: pointer, kind: .number, text: text) { leaves.append(leaf) }
                case .bool(let flag):
                    if let leaf = try? StructuredField(path: pointer, kind: .boolean, text: flag ? "true" : "false") {
                        leaves.append(leaf)
                    }
                case .null:
                    if let leaf = try? StructuredField(path: pointer, kind: .null, text: nil) { leaves.append(leaf) }
            }
        }
        walk(value, "")
        return leaves.filter { $0.path != "/" }
    }

    /// A key as a JSON pointer writes it: `~` as `~0`, `/` as `~1`.
    static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}
