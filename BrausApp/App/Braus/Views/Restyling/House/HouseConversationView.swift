//
//  HouseConversationView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseConversationView is the conversation with the chosen worker: the worker at the top centre,
/// the messages under it in a column that fades out at its top, and the composer at the foot.
///
/// The messages are a static sample; what the person sends is added after them.
struct HouseConversationView: View {
    let worker           : MockWorker
    let isComposerFocused: FocusState<Bool>.Binding

    @State private var sent: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HouseHero(worker: worker)
                .padding(
                    .top,
                    6
                )
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(
                        Self.sample.indices,
                        id: \.self
                    ) { index in
                        line(Self.sample[index])
                    }
                    ForEach(
                        sent.indices,
                        id: \.self
                    ) { index in
                        line(.person(sent[index]))
                    }
                }
                .padding(
                    .vertical,
                    22
                )
                .frame(maxWidth: Self.columnWidth)
                .padding(
                    .horizontal,
                    24
                )
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(
                .bottom,
                for: .sizeChanges
            )
            .mask {
                LinearGradient(
                    stops     : [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.1),
                    ],
                    startPoint: .top,
                    endPoint  : .bottom
                )
            }
            HouseComposer(
                worker   : worker,
                isFocused: isComposerFocused
            ) { sent.append($0) }
                .frame(maxWidth: Self.columnWidth)
                .padding(
                    .horizontal,
                    24
                )
                .padding(
                    .bottom,
                    20
                )
        }
    }

    /// The width of the messages and the composer, as the prototype's column.
    private static let columnWidth: CGFloat = 560

    /// Line is one entry of the conversation.
    private enum Line {
        case person(String)
        case worker(String)
        case tool(String)
    }

    private static let sample: [Line] = [
        .person("Export the open Pro Tools session as an AAF into the Delivery folder."),
        .tool("Opened Pro Tools and read the session"),
        .worker("I’m checking the session, exporting the AAF, and I’ll confirm the delivery."),
        .worker("The dialog has a preset I don’t know. Keep it, or use stereo interleaved?"),
        .person("Stereo interleaved."),
    ]

    @ViewBuilder
    private func line(_ line: Line) -> some View {
        switch line {
        case .person(let text):
            bubble(
                text,
                from: .trailing
            ) {
                $0.fill(LinearGradient(
                    colors    : [Color(white: 0.24), Color(white: 0.17)],
                    startPoint: UnitPoint(x: 0.33, y: 0),
                    endPoint  : UnitPoint(x: 0.67, y: 1)
                ))
            }
        case .worker(let text):
            bubble(
                text,
                from: .leading
            ) { shape in
                shape
                    .fill(.white.opacity(0.04))
                    .overlay { shape.strokeBorder(.white.opacity(0.07)) }
            }
        case .tool(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(
                    .leading,
                    4
                )
                .padding(
                    .bottom,
                    -4
                )
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
        }
    }

    /// A message's text on `fill`, at most 78% of the column wide, on its sender's side.
    private func bubble(
        _ text: String,
        from edge: HorizontalEdge,
        @ViewBuilder fill: (UnevenRoundedRectangle) -> some View
    ) -> some View {
        let alignment: Alignment = edge == .leading ? .leading : .trailing
        return Text(text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(
                .horizontal,
                16
            )
            .padding(
                .vertical,
                11
            )
            .background { fill(bubbleShape(tailing: edge)) }
            .frame(
                maxWidth : Self.columnWidth * 0.78,
                alignment: alignment
            )
            .frame(
                maxWidth : .infinity,
                alignment: alignment
            )
    }

    /// A 21 point rounded bubble whose corner on `edge`'s bottom is tighter, pointing at its sender.
    private func bubbleShape(tailing edge: HorizontalEdge) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius    : 21,
            bottomLeadingRadius : edge == .leading ? 8 : 21,
            bottomTrailingRadius: edge == .trailing ? 8 : 21,
            topTrailingRadius   : 21,
            style               : .continuous
        )
    }
}
