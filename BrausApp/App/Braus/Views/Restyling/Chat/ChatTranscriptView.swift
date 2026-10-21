//
//  ChatTranscriptView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// ChatTranscriptView is the conversation's messages in a column that fades out at its top and
/// keeps its foot in view: the person's bubbles on the trailing side, the passage they quote at
/// their top, the worker's on the leading side with their tool line above them.
///
/// A bubble in `landing`, always the last message, is laid out but not drawn while a flight carries
/// its text in. Its place across and its size in `BubbleFlight.space` go to `onLandingFrame`, with
/// no height on screen: while the transcript makes room, its geometry moves frame by frame, so the
/// caller places it above the transcript's resting foot, `endPadding` under it. The column's width
/// goes to `onColumnWidth`, so a flight can break its text into the bubble's lines beforehand.
///
/// Hovering a bubble shows its reply button beside it, also a VoiceOver action; choosing it nudges
/// and dims the bubble and hands it to `onReply`. `frames` keeps every bubble's frame. Whether the
/// transcript shows its end goes to `onAtEnd`; `position` scrolls it there.
struct ChatTranscriptView: View {
    let messages      : [MockConversation.Message]
    let landing       : Set<MockConversation.Message.ID>
    let frames        : Frames

    @Binding var position: ScrollPosition

    let onLandingFrame: (MockConversation.Message.ID, CGRect) -> Void
    let onColumnWidth : (CGFloat) -> Void
    let onAtEnd       : (Bool) -> Void
    let onReply       : (MockConversation.Message) -> Void

    /// The width of the messages and the composer, as the prototype's column.
    static let columnWidth: CGFloat = 560

    /// The widest a bubble grows, 78% of the full column.
    static let maximumBubbleWidth = columnWidth * 0.78

    /// The room between a bubble's edge and its text.
    static let bubblePadding = EdgeInsets(
        top     : 11,
        leading : 16,
        bottom  : 11,
        trailing: 16
    )

    /// The room above the first message and under the last.
    static let endPadding: CGFloat = 22

    /// The person's fill, light at the top leading corner to dark at the bottom trailing one.
    static let personFill = (
        colors: [Color(white: 0.24), Color(white: 0.17)],
        start : UnitPoint(x: 0.33, y: 0),
        end   : UnitPoint(x: 0.67, y: 1)
    )

    /// The bubble the pointer is on, or on whose reply button.
    @State private var hovered: MockConversation.Message.ID?

    /// How many times each bubble was chosen for a reply, which plays its nudge.
    @State private var nudges: [MockConversation.Message.ID: Int] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(messages) { message in
                    row(message)
                }
            }
            // The worker's bubble springs in, widens into its reply, and the transcript makes room.
            .animation(
                BubbleFlight.transcriptAnimation,
                value: messages
            )
            .padding(
                .vertical,
                Self.endPadding
            )
            .frame(maxWidth: Self.columnWidth)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                onColumnWidth(width)
            }
            .padding(
                .horizontal,
                24
            )
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(
            .bottom,
            for: .sizeChanges
        )
        .onScrollGeometryChange(
            for: Bool.self,
            of : Self.showsEnd
        ) { _, showsEnd in
            onAtEnd(showsEnd)
        }
        // The fade at the top; the mask reaches under the floating composer, whose ground fades the foot.
        .mask {
            LinearGradient(
                stops     : [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.1),
                ],
                startPoint: .top,
                endPoint  : .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// Whether `geometry` shows the content's end, within a point or two. The container's size is the
    /// part the content scrolls in, its insets left out.
    nonisolated private static func showsEnd(_ geometry: ScrollGeometry) -> Bool {
        let end = geometry.contentSize.height - geometry.containerSize.height
        return geometry.contentOffset.y >= end - 2
    }

    /// The text of a bubble as every bubble and every flight draws it.
    static func bubbleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(3)
    }

    /// What a person's bubble holds: the passage it quotes, if any, above its text.
    static func personContent(
        _ text: String,
        quote : String?
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 7
        ) {
            if let quote {
                Text(quote)
                    .font(QueueStrip.font)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(
                        .leading,
                        9
                    )
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.white.opacity(0.35))
                            .frame(width: 2)
                    }
            }
            bubbleText(text)
        }
    }

    /// The width a bubble's text may take in a column `column` points wide.
    static func maximumTextWidth(column: CGFloat) -> CGFloat {
        min(column, maximumBubbleWidth) - bubblePadding.leading - bubblePadding.trailing
    }

    /// A 21 point rounded bubble whose corner on `edge`'s bottom is tighter, pointing at its sender.
    static func bubbleShape(tailing edge: HorizontalEdge) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius    : 21,
            bottomLeadingRadius : edge == .leading ? 8 : 21,
            bottomTrailingRadius: edge == .trailing ? 8 : 21,
            topTrailingRadius   : 21,
            style               : .continuous
        )
    }

    /// `content` in the worker's bubble on the leading side, at most `maximumBubbleWidth` wide, with
    /// the reply button and frame keeping of `quotable`.
    static func workerBubble(
        quotable: Quotable,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        let shape = bubbleShape(tailing: .leading)
        return content()
            .padding(bubblePadding)
            .background {
                shape
                    .fill(.white.opacity(0.04))
                    .overlay { shape.strokeBorder(.white.opacity(0.07)) }
            }
            .modifier(quotable)
            .frame(
                maxWidth : maximumBubbleWidth,
                alignment: .leading
            )
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
    }

    @ViewBuilder
    private func row(_ message: MockConversation.Message) -> some View {
        switch message.author {
        case .person:
            personBubble(message)
        case .worker:
            AnswerBubble(
                message: message,
                quotable: quotable(
                    message,
                    from: .leading
                )
            )
            .transition(.asymmetric(
                insertion: .scale(
                    scale : 0.6,
                    anchor: .bottomLeading
                )
                .combined(with: .opacity)
                .combined(with: .offset(y: 10)),
                removal  : .opacity
            ))
        }
    }

    /// The person's message on the trailing side, hidden while its flight is in the air.
    private func personBubble(_ message: MockConversation.Message) -> some View {
        let isLanding = landing.contains(message.id)
        return Self.personContent(
            message.text,
            quote: message.quote
        )
        .textSelection(.enabled)
        .padding(Self.bubblePadding)
        .background {
            Self.bubbleShape(tailing: .trailing)
                .fill(LinearGradient(
                    colors    : Self.personFill.colors,
                    startPoint: Self.personFill.start,
                    endPoint  : Self.personFill.end
                ))
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            // Only its place across and its size: its height on screen moves as the transcript does.
            let frame = proxy.frame(in: .named(BubbleFlight.space))
            return CGRect(
                x     : frame.minX,
                y     : 0,
                width : frame.width,
                height: frame.height
            )
        } action: { frame in
            if isLanding { onLandingFrame(message.id, frame) }
        }
        .opacity(isLanding ? 0 : 1)
        .modifier(quotable(
            message,
            from: .trailing
        ))
        .frame(
            maxWidth : Self.maximumBubbleWidth,
            alignment: .trailing
        )
        .frame(
            maxWidth : .infinity,
            alignment: .trailing
        )
        .transition(.identity)
    }

    private func quotable(
        _ message: MockConversation.Message,
        from edge: HorizontalEdge
    ) -> Quotable {
        Quotable(
            message  : message,
            edge     : edge,
            frames   : frames,
            isHovered: hovered == message.id && !message.isThinking,
            nudges   : nudges[message.id] ?? 0,
            onHover  : { isIn in
                if isIn {
                    hovered = message.id
                } else if hovered == message.id {
                    hovered = nil
                }
            },
            onReply  : {
                nudges[message.id, default: 0] += 1
                onReply(message)
            }
        )
    }

    // MARK: Frames

    /// Frames keeps each bubble's latest frame in `BubbleFlight.space`, for flights that start or
    /// end at a bubble. A reference, so that keeping a frame redraws nothing.
    @MainActor
    final class Frames {
        private var frames: [MockConversation.Message.ID: CGRect] = [:]

        subscript(id: MockConversation.Message.ID) -> CGRect? { frames[id] }

        fileprivate func keep(
            _ frame: CGRect,
            for id : MockConversation.Message.ID
        ) {
            frames[id] = frame
        }
    }

    // MARK: Quotable

    /// Quotable gives a bubble its reply button on the outer side, shown while the pointer is on
    /// the bubble or the button, and a Reply action for VoiceOver; it keeps the bubble's frame, and
    /// a reply nudges the bubble outward and dims it a moment (the dim only, under Reduce Motion).
    /// SwiftUI plays the nudge, as Core Animation cannot reach a SwiftUI bubble.
    struct Quotable: ViewModifier {
        let message  : MockConversation.Message
        let edge     : HorizontalEdge
        let frames   : Frames
        let isHovered: Bool
        let nudges   : Int
        let onHover  : (Bool) -> Void
        let onReply  : () -> Void

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(BubbleFlight.space))
                } action: { frame in
                    frames.keep(
                        frame,
                        for: message.id
                    )
                }
                .keyframeAnimator(
                    initialValue: Nudge(),
                    trigger     : nudges
                ) { bubble, nudge in
                    bubble
                        .offset(x: nudge.offset)
                        .opacity(nudge.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.offset) {
                        SpringKeyframe(
                            RestylingMotion.reducesMotion ? 0 : (edge == .trailing ? -6 : 6),
                            duration: 0.18
                        )
                        SpringKeyframe(
                            0,
                            duration: 0.27
                        )
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(
                            0.55,
                            duration: 0.28
                        )
                        LinearKeyframe(
                            1,
                            duration: 0.42
                        )
                    }
                }
                .overlay(alignment: edge == .trailing ? .leading : .trailing) {
                    // The gap to the bubble is part of the button's hover area, so it stays shown.
                    replyButton
                        .padding(
                            edge == .trailing ? .trailing : .leading,
                            10
                        )
                        .contentShape(Rectangle())
                        .onHover(perform: onHover)
                        .offset(x: edge == .trailing ? -38 : 38)
                }
                .onHover(perform: onHover)
                .accessibilityAction(
                    named: "Reply",
                    onReply
                )
        }

        private var replyButton: some View {
            Button(
                "Reply",
                systemImage: "arrowshape.turn.up.left",
                action     : onReply
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(
                width : 28,
                height: 28
            )
            .background(
                .white.opacity(0.08),
                in: Circle()
            )
            .contentShape(Circle())
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.8)
            .animation(
                .easeOut(duration: 0.18),
                value: isHovered
            )
            .help("Reply")
            .accessibilityHidden(true)
        }

        /// Nudge is the bubble's sideways shift and opacity as it is chosen for a reply.
        struct Nudge {
            var offset : CGFloat = 0
            var opacity: Double  = 1
        }
    }
}
