//
//  ChatScript.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import ChatCore
import Foundation
import LocalMCP

/// ChatScript is what `braus chat --script` reads and derives apart from any process: the requests of a script file,
/// the tasks a conversation's tool lines name, and the differences between the identity a preflight expects and the
/// one a process answered. Pure, so a test reads them without a provider.
enum ChatScript {

    /// Request is one request of a script: its text, and whether it continues the conversation of the request before
    /// it, as a reply does, instead of opening a new one (its first line started with `>`).
    struct Request: Equatable {
        let text: String
        let continuesPrevious: Bool
    }

    /// The requests of a script: blocks of consecutive non-empty lines, separated by one or more empty lines, each
    /// block one request with its lines kept; a line whose first non-blank character is `#` is a comment and belongs
    /// to no block; a block whose first line starts with `>` continues the conversation of the block before it (the
    /// `>` is not sent; a first block's `>` opens a conversation as any). A request is sent as written, trimmed of its
    /// surrounding blank space.
    static func requests(in text: String) -> [Request] {
        var requests: [Request] = []
        var block: [String] = []
        func close() {
            var lines = block
            var continues = false
            if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix(">") {
                continues = true
                lines[0] = String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let request = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !request.isEmpty { requests.append(Request(text: request, continuesPrevious: continues && !requests.isEmpty)) }
            block = []
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { close(); continue }
            if trimmed.hasPrefix("#") { continue }
            block.append(line)
        }
        close()
        return requests
    }

    /// The tasks a conversation's tool lines name, in the order the memory first answered them, each once: the `task`
    /// of every `memory_task` answer (`← memory_task {…}`), which `begin` opens and every later operation repeats.
    static func taskIDs(in entries: [Conversation.Entry]) -> [String] {
        var ids: [String] = []
        let prefix = "← memory_task "
        for entry in entries where entry.kind == .tool && entry.text.hasPrefix(prefix) {
            let json = String(entry.text.dropFirst(prefix.count))
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
                  let id = value["task"].string, !id.isEmpty, !ids.contains(id) else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Difference is one place where what a process answered is not what the preflight expected.
    struct Difference: Equatable, CustomStringConvertible {
        let path: String
        let expected: String
        let found: String
        var description: String { "\(path): expected \(expected), found \(found)" }
    }

    /// The differences between the identity expected and the one found, over the keys the expectation names: an
    /// object is compared key by key, any other value whole; a key the answer lacks is `absent`. Keys the expectation
    /// does not name are not compared, so an expectation states only what the run depends on.
    static func differences(expected: JSONValue, found: JSONValue, at path: String = "") -> [Difference] {
        switch expected {
            case .object(let fields):
                return fields.keys.sorted().flatMap { key -> [Difference] in
                    let next = path.isEmpty ? key : "\(path).\(key)"
                    guard let value = fields[key] else { return [] }
                    guard let inside = found.object, let answered = inside[key] else {
                        return [Difference(path: next, expected: text(value), found: "absent")]
                    }
                    return differences(expected: value, found: answered, at: next)
                }
            default:
                return expected == found ? [] : [Difference(path: path.isEmpty ? "value" : path, expected: text(expected), found: text(found))]
        }
    }

    /// The value a tool answered, out of the result the MCP router wraps it in (`content[0].text`, JSON): the result
    /// itself when it is not such a wrapping.
    static func payload(of result: JSONValue) -> JSONValue {
        guard let text = result["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return result }
        return value
    }

    /// A JSON value as one line of text, for a difference and for the evidence.
    static func text(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}
