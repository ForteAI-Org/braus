//
//  QueueStrip.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// QueueStrip is the tab joined above the composer that holds what the person sent while the worker
/// answers: one message at a time, ‹ 2/3 › to page through several, Send Now, and a button that
/// takes the shown message out. It shows `items` with the one at `page`, and asks `onPage` to show
/// another; the mockup passes its `MessageQueue`, the app its conversation's queue.
///
/// The shown message's frame in `BubbleFlight.space` goes to `onTextFrame`, where a flight lands;
/// while `hidesText`, its text is laid out but not drawn, as a flight carries it in or out. With
/// `onEdit`, a click on it takes it back into the draft to be edited.
struct QueueStrip: View {
    let items      : [String]
    let page       : Int
    let hidesText  : Bool
    let onTextFrame: (CGRect) -> Void
    let onPage     : (Int) -> Void
    let onSendNow  : () -> Void
    let onDrop     : () -> Void
    var onEdit     : (() -> Void)?

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
                    .stripAction(
                        onEdit,
                        help: "Edit this queued message."
                    )
            }
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
            if items.count > 1 {
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
        items.indices.contains(page) ? items[page] : ""
    }

    /// ‹ 2/3 ›: the shown message's place among the queued, and the buttons that turn to the
    /// previous and the next, round the ends.
    private var pager: some View {
        HStack(spacing: 2) {
            Button(
                "Previous Message",
                systemImage: "chevron.left"
            ) {
                onPage((page + items.count - 1) % items.count)
            }
            Text("\(page + 1)/\(items.count)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(
                "Next Message",
                systemImage: "chevron.right"
            ) {
                onPage((page + 1) % items.count)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
