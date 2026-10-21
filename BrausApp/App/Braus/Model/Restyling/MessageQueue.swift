//
//  MessageQueue.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// MessageQueue holds what the person sends while the worker is answering, oldest first, and which
/// of them the strip above the composer shows (`page`): the one that goes next.
///
/// The strip starts on the oldest and stays where the person pages it as more arrive. The end of the
/// turn and Send Now both take out the shown message, so what flies out is the line the strip shows;
/// the strip then shows the oldest again. `page` stays on a message while there is one, and is 0
/// when there is none.
nonisolated struct MessageQueue: Equatable, Sendable {
    private(set) var items: [String] = []

    var page = 0

    /// Queues `text` behind the others; the strip keeps showing the message that goes next.
    mutating func add(_ text: String) {
        items.append(text)
    }

    /// Takes the shown message out, to send it now.
    mutating func sendNow() -> String? {
        takeShown()
    }

    /// Removes the shown message, showing the one before it.
    mutating func drop() {
        guard items.indices.contains(page) else { return }

        items.remove(at: page)
        page = min(max(0, page - 1), max(0, items.count - 1))
    }

    /// Takes the shown message out, for the turn that starts.
    mutating func endOfTurn() -> String? {
        takeShown()
    }

    private mutating func takeShown() -> String? {
        guard items.indices.contains(page) else { return nil }

        let text = items.remove(at: page)
        page = 0
        return text
    }
}
