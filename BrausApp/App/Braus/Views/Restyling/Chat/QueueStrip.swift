//
//  QueueStrip.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// QueueStrip is the tab joined above the composer that holds what the person sent while the worker
/// answers: one message at a time, ‹ 2/3 › to page through several, Send Now, and a button that
/// takes the shown message out.
///
/// The shown message's frame in `BubbleFlight.space` goes to `onTextFrame`, where a flight lands;
/// while `hidesText`, its text is laid out but not drawn, as a flight carries it in or out.
struct QueueStrip: View {
    @Binding var queue: MessageQueue
    let hidesText     : Bool
    let onTextFrame   : (CGRect) -> Void
    let onSendNow     : () -> Void
    let onDrop        : () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(
                alignment: .leading,
                spacing  : 2
            ) {
                Text("Queued · Sends When the Turn Ends")
                    .font(.system(size: 10.5))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                Text(shown)
                    .font(Self.font)
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
            if queue.items.count > 1 {
                pager
            }
            Button(
                "Send Now",
                action: onSendNow
            )
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .help("Stop the turn and send this message now.")
            Button(
                "Remove from Queue",
                systemImage: "xmark",
                action     : onDrop
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove this message from the queue.")
        }
        .modifier(ComposerTab())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
    }

    /// The font of a strip's message, smaller than the composer's.
    static let font = Font.system(size: 12.5)

    private var shown: String {
        queue.items.indices.contains(queue.page) ? queue.items[queue.page] : ""
    }

    /// ‹ 2/3 ›: the shown message's place among the queued, and the buttons that turn to the
    /// previous and the next, round the ends.
    private var pager: some View {
        HStack(spacing: 2) {
            Button(
                "Previous Message",
                systemImage: "chevron.left"
            ) {
                queue.page = (queue.page + queue.items.count - 1) % queue.items.count
            }
            Text("\(queue.page + 1)/\(queue.items.count)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(
                "Next Message",
                systemImage: "chevron.right"
            ) {
                queue.page = (queue.page + 1) % queue.items.count
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
