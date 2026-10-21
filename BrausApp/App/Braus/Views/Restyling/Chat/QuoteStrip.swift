//
//  QuoteStrip.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// QuoteStrip is the tab joined above the composer that shows the message the next one replies
/// to: who wrote it and its first line, with a button that takes the quote back.
///
/// The quoted line's frame in `BubbleFlight.space` goes to `onTextFrame`, where the quote's flight
/// lands; while `hidesText`, that line is laid out but not drawn.
struct QuoteStrip: View {
    let title      : String
    let text       : String
    let hidesText  : Bool
    let onTextFrame: (CGRect) -> Void
    let onRemove   : () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(
                alignment: .leading,
                spacing  : 1
            ) {
                Text(title)
                    .font(.system(
                        size  : 12,
                        weight: .medium
                    ))
                Text(text)
                    .font(QueueStrip.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(hidesText ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(BubbleFlight.space))
                    } action: { frame in
                        onTextFrame(frame)
                    }
            }
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
            Button(
                "Remove Quote",
                systemImage: "xmark",
                action     : onRemove
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Don’t reply to this message.")
        }
        .modifier(ComposerTab())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(text)")
    }
}
