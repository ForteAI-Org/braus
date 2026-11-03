//
//  PicturesEnlargement.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/11/2026.
//

import AppKit

/// PicturesEnlargement is a tool line's pictures enlarged over the window: grown from the small
/// pictures in the transcript (`opener`) and shrunk back into them when it closes.
///
/// Closing only marks the value; the overlay removes it once its animation has landed, as a
/// worker's enlarged screen (`ScreenEnlargement`).
struct PicturesEnlargement: Equatable {

    let id = UUID()
    let images: [NSImage]
    let sizes : [CGSize]
    let label : String

    /// The small pictures it grows from and shrinks into, gone when their row scrolled away.
    weak var opener: NSView?

    /// True from the request to close until the overlay is removed.
    private(set) var isClosing = false

    init(
        images: [NSImage],
        sizes : [CGSize],
        label : String,
        opener: NSView?
    ) {
        self.images = images
        self.sizes  = sizes
        self.label  = label
        self.opener = opener
    }

    mutating func close() { isClosing = true }

    static func == (
        lhs: PicturesEnlargement,
        rhs: PicturesEnlargement
    ) -> Bool {
        lhs.id == rhs.id && lhs.isClosing == rhs.isClosing
    }
}
