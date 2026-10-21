//
//  ScreenEnlargement.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import Foundation

/// ScreenPlace is where a worker's live screen sits: small at the top right of the
/// conversation or in the inspector, as the toolbar's screen toggle chooses, or in its
/// own window.
enum ScreenPlace: Hashable {

    case conversation
    case inspector
    case window

    /// Where the screen rests while the toggle is `showsInConversation`.
    static func resting(showsInConversation: Bool) -> ScreenPlace {
        showsInConversation ? .conversation : .inspector
    }
}

/// ScreenEnlargement is one worker's screen enlarged over the conversation: it
/// grows from the place it was opened from and shrinks into the place the
/// toggle names when it closes, which is the origin unless the toggle moved.
///
/// Closing only marks the value; the overlay removes it once its animation
/// has landed, so the screen is never without a place to land in.
struct ScreenEnlargement: Equatable {

    let workerID: UUID
    let origin  : ScreenPlace

    /// True from the request to close until the overlay is removed.
    private(set) var isClosing = false

    init(
        workerID: UUID,
        origin  : ScreenPlace
    ) {
        self.workerID = workerID
        self.origin   = origin
    }

    mutating func close() { isClosing = true }

    /// The place the screen shrinks into, read when it closes.
    func destination(showsInConversation: Bool) -> ScreenPlace {
        .resting(showsInConversation: showsInConversation)
    }
}
