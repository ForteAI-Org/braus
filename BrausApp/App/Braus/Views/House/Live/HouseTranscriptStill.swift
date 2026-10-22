//
//  HouseTranscriptStill.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// HouseTranscriptStill is a leaving conversation's transcript as it was drawn when another worker
/// was chosen (`HouseSwitch`), laid over the window's one transcript while it opens the arriving
/// conversation and fading out over it. The image keeps its size and sits at the top leading corner,
/// where the transcript it was taken from begins.
struct HouseTranscriptStill: NSViewRepresentable {
    let image: NSImage

    /// The image of what `view` shows now, or nil while it has no size.
    static func image(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard !bounds.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }

        view.cacheDisplay(
            in: bounds,
            to: bitmap
        )
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    func makeNSView(context: Context) -> StillView {
        let view = StillView()
        view.imageScaling   = .scaleNone
        view.imageAlignment = .alignTopLeft
        view.image          = image
        view.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        view.setContentHuggingPriority(
            .defaultLow,
            for: .vertical
        )
        view.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        view.setContentCompressionResistancePriority(
            .defaultLow,
            for: .vertical
        )
        return view
    }

    func updateNSView(
        _ view : StillView,
        context: Context
    ) {
        if view.image !== image { view.image = image }
    }

    /// Takes the space it is offered, never the image's.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : StillView,
        context   : Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    /// StillView shows the still and lets every click through to the transcript under it.
    final class StillView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
