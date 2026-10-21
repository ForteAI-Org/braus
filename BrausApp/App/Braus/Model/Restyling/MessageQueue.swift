//
//  MessageQueue.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// MessageQueue holds what the person sends while the worker is answering, oldest first, and which
/// of them the strip above the composer shows (`page`).
///
/// A new message is shown at once. The end of a turn sends the oldest; Send Now sends the shown one.
/// Whatever is taken out, `page` stays on a message while there is one, and is 0 when there is none.
nonisolated struct MessageQueue: Equatable, Sendable {
    private(set) var items: [String] = []

    var page = 0

    /// Queues `text` and shows it.
    mutating func add(_ text: String) {
        items.append(text)
        page = items.count - 1
    }

    /// Takes the shown message out, to send it now.
    mutating func sendNow() -> String? {
        guard items.indices.contains(page) else { return nil }

        let text = items.remove(at: page)
        page = min(page, max(0, items.count - 1))
        return text
    }

    /// Removes the shown message, showing the one before it.
    mutating func drop() {
        guard items.indices.contains(page) else { return }

        items.remove(at: page)
        page = min(max(0, page - 1), max(0, items.count - 1))
    }

    /// Takes the oldest message out, for the turn that starts; the strip keeps showing the same one.
    mutating func endOfTurn() -> String? {
        guard !items.isEmpty else { return nil }

        page = max(0, page - 1)
        return items.removeFirst()
    }
}
