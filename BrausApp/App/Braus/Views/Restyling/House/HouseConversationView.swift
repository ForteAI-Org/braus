//
//  HouseConversationView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseConversationView is the conversation with the chosen worker: the worker at the top centre,
/// the transcript under it, and the composer at the foot.
///
/// A message the person sends flies from the composer's field into its bubble at the transcript's
/// foot (`BubbleFlight`), while the transcript makes room for it with the flight's spring; the
/// bubble is drawn once the flight lands, and the worker answers it. What the person sends while
/// the worker answers flies into the queue strip above the composer instead; at the end of the
/// turn, or on Send Now, a queued message flies from the strip into the transcript.
struct HouseConversationView: View {
    let worker           : MockWorker
    let isComposerFocused: FocusState<Bool>.Binding

    @State private var conversation: MockConversation

    @State private var flight = BubbleFlight()

    /// The messages whose flight has not landed yet, laid out but not drawn.
    @State private var landing: Set<MockConversation.Message.ID> = []

    /// What the person is writing in the composer.
    @State private var draft = ""

    /// Where the transcript's foot rests in `BubbleFlight.space`, above the composer.
    @State private var foot: CGFloat = 0

    /// The queue strip's line, where queued messages land and leave from.
    @State private var queueLine = CGRect.zero

    /// Whether the queue strip's line waits for a flight carrying its text in.
    @State private var isQueueLanding = false

    /// The quote strip's line, where a quote lands and leaves from.
    @State private var quoteLine = CGRect.zero

    /// Whether the quote strip's line waits for the quote's flight.
    @State private var isQuoteLanding = false

    /// Every bubble's latest frame, where quotes leave from and return to.
    @State private var frames = ChatTranscriptView.Frames()

    /// The transcript column's width, which breaks a flight's text as its bubble will.
    @State private var columnWidth = ChatTranscriptView.columnWidth

    init(
        worker           : MockWorker,
        isComposerFocused: FocusState<Bool>.Binding
    ) {
        self.worker            = worker
        self.isComposerFocused = isComposerFocused
        _conversation          = State(initialValue: MockConversation(workerName: worker.name))
    }

    var body: some View {
        VStack(spacing: 0) {
            HouseHero(
                worker     : worker,
                status     : conversation.phase == .idle ? worker.status : .busy,
                brows      : heroBrows,
                activity   : heroActivity,
                preparation: conversation.turns
            )
            .padding(
                .top,
                6
            )
            ChatTranscriptView(
                messages      : conversation.messages,
                landing       : landing,
                frames        : frames,
                onLandingFrame: land,
                onColumnWidth : { columnWidth = $0 },
                onReply       : reply
            )
            // The transcript's foot as it rests: unanimated, it reports the layout's final frame
            // while the composer and the transcript animate toward it.
            Color.clear
                .frame(height: 0)
                .transaction { $0.animation = nil }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(BubbleFlight.space)).minY
                } action: { minY in
                    foot = minY
                }
            dock
                .frame(maxWidth: ChatTranscriptView.columnWidth)
                .padding(
                    .horizontal,
                    24
                )
                .padding(
                    .bottom,
                    20
                )
        }
        // The composer grows and shrinks with the draft, a strip comes and goes above it, and the
        // transcript gives way, together.
        .animation(
            BubbleFlight.transcriptAnimation,
            value: draft
        )
        .animation(
            BubbleFlight.transcriptAnimation,
            value: conversation.queue.items.isEmpty
        )
        .animation(
            BubbleFlight.transcriptAnimation,
            value: conversation.quote?.id
        )
        .coordinateSpace(.named(BubbleFlight.space))
        .overlay {
            flight.overlay
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The composer with the strips joined above it.
    private var dock: some View {
        VStack(spacing: 0) {
            if !conversation.queue.items.isEmpty {
                QueueStrip(
                    queue      : $conversation.queue,
                    hidesText  : isQueueLanding,
                    onTextFrame: { queueLine = $0 },
                    onSendNow  : sendNow,
                    onDrop     : drop
                )
                .transition(.opacity)
            }
            if let quote = conversation.quote {
                QuoteStrip(
                    title      : quote.author == .worker ? "Reply to \(worker.name)" : "Reply to Your Message",
                    text       : quote.text,
                    hidesText  : isQuoteLanding,
                    onTextFrame: { quoteLine = $0 },
                    onRemove   : unquote
                )
                .transition(.opacity)
            }
            HouseComposer(
                worker   : worker,
                text     : $draft,
                isFocused: isComposerFocused,
                onSend   : send
            )
        }
    }

    /// The worker's brows: listening while it reads or while the person writes to it between
    /// turns, at work while it answers, and its status's otherwise.
    private var heroBrows: BrowState {
        switch conversation.phase {
        case .reading: .listening
        case .working: .working
        case .idle   : draft.allSatisfy(\.isWhitespace) ? BrowState(worker.status) : .listening
        }
    }

    private var heroActivity: String {
        switch conversation.phase {
        case .reading: "Reading"
        case .working: "Working"
        case .idle   : worker.subtitle
        }
    }

    /// Sends `text`, typed in `field` and scrolled by `scroll` when known: into the transcript, or
    /// into the queue while the worker answers.
    private func send(
        _ text: String,
        from field: CGRect,
        scrolled scroll: CGFloat?
    ) {
        // A queued text's line waits for its flight, unanimated, whatever animates around it.
        if conversation.isAnswering { isQueueLanding = true }
        withAnimation(BubbleFlight.transcriptAnimation) {
            if let message = conversation.send(text) {
                fly(
                    message,
                    from: .field(
                        field,
                        scroll: scroll
                    )
                )
            } else {
                queue(
                    text,
                    from: .field(
                        field,
                        scroll: scroll
                    )
                )
            }
        }
    }

    /// Carries `text`, just queued and shown in the strip, from the composer's field into the
    /// strip's line, which shows it once it is there.
    private func queue(
        _ text: String,
        from field: BubbleFlight.Origin
    ) {
        let id = UUID()
        flight.launch(
            id,
            text  : text,
            quote : nil,
            from  : field,
            column: columnWidth
        )
        // A turn later, once the strip has laid out its line.
        DispatchQueue.main.async {
            flight.glide(
                id,
                to: queueLine
            ) {
                showQueueLine()
            }
        }
    }

    /// Lays `message` out hidden at the transcript's foot, with room made for it, and starts its
    /// flight from `origin`, where its text was.
    private func fly(
        _ message: MockConversation.Message,
        from origin: BubbleFlight.Origin
    ) {
        landing.insert(message.id)
        flight.launch(
            message.id,
            text  : message.text,
            quote : message.quote,
            from  : origin,
            column: columnWidth
        )
    }

    /// Flies a landing message to its bubble, `bubble` across and in size, above the transcript's
    /// resting foot; draws the bubble once it is there, and has the worker answer it.
    private func land(
        _ id  : MockConversation.Message.ID,
        bubble: CGRect
    ) {
        // A turn later, once the foot has reported the same layout, which it may do after the bubble.
        DispatchQueue.main.async {
            touchDown(
                id,
                at: CGRect(
                    x     : bubble.minX,
                    y     : foot - ChatTranscriptView.endPadding - bubble.height,
                    width : bubble.width,
                    height: bubble.height
                )
            )
        }
    }

    private func touchDown(
        _ id    : MockConversation.Message.ID,
        at frame: CGRect
    ) {
        flight.land(
            id,
            in: frame
        ) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                _ = landing.remove(id)
            }
            conversation.answer { sendQueued() }
        }
    }

    /// Fades the queue strip's line in.
    private func showQueueLine() {
        withAnimation(.easeOut(duration: BubbleFlight.crossFade)) { isQueueLanding = false }
    }

    /// At the end of a turn, sends the oldest queued message from the strip.
    private func sendQueued() {
        let line = queueLine
        guard !conversation.queue.items.isEmpty else { return }

        isQueueLanding = true
        withAnimation(BubbleFlight.transcriptAnimation) {
            guard let message = conversation.sendQueued() else { return }

            leaveQueue(
                message,
                from: line
            )
        }
    }

    /// Stops the turn and sends the queued message the strip shows.
    private func sendNow() {
        let line = queueLine
        isQueueLanding = true
        withAnimation(BubbleFlight.transcriptAnimation) {
            guard let message = conversation.sendNow() else { return }

            leaveQueue(
                message,
                from: line
            )
        }
    }

    /// Flies `message` from the strip's `line`, hidden by the caller, which shows the next queued
    /// message once this one has lifted off it.
    private func leaveQueue(
        _ message: MockConversation.Message,
        from line: CGRect
    ) {
        fly(
            message,
            from: .strip(line)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + BubbleFlight.reflow.typedOut.end) {
            showQueueLine()
        }
    }

    /// Quotes `message` in the next one the person sends: a copy of its bubble flies into the quote
    /// strip, whose line shows once it is there; under Reduce Motion the strip fades in.
    private func reply(to message: MockConversation.Message) {
        let bubble  = frames[message.id]
        let flies   = bubble != nil && !RestylingMotion.reducesMotion
        // Unanimated, whatever animates around it: the line waits for the flight.
        isQuoteLanding = flies
        withAnimation(BubbleFlight.transcriptAnimation ?? .easeOut(duration: BubbleFlight.crossFade)) {
            conversation.quote = message
        }
        isComposerFocused.wrappedValue = true
        guard flies, let bubble else { return }

        // A turn later, once the strip has laid out its line.
        DispatchQueue.main.async {
            let content = ChatTranscriptView.personContent(
                message.text,
                quote: message.author == .person ? message.quote : nil
            )
            flight.quote(
                content,
                fill      : Rectangle().fill(message.author == .person
                    ? AnyShapeStyle(LinearGradient(
                        colors    : ChatTranscriptView.personFill.colors,
                        startPoint: ChatTranscriptView.personFill.start,
                        endPoint  : ChatTranscriptView.personFill.end
                    ))
                    : AnyShapeStyle(.white.opacity(0.04))),
                from      : bubble,
                to        : quoteLine,
                lineText  : message.text
            ) {
                isQuoteLanding = false
            }
        }
    }

    /// Takes the quote back: its line flies back into its bubble as the strip closes.
    private func unquote() {
        guard let quote = conversation.quote else { return }

        let bubble = frames[quote.id]
        let rest   = foot
        flight.unquote(
            from    : quoteLine,
            lineText: quote.text
        ) {
            // The transcript, anchored at its foot, moves down as far as the foot does.
            bubble?.offsetBy(
                dx: 0,
                dy: foot - rest
            )
        }
        isQuoteLanding = true
        withAnimation(BubbleFlight.transcriptAnimation) {
            conversation.quote = nil
        }
    }

    /// Takes the shown message out of the queue.
    private func drop() {
        withAnimation(.easeOut(duration: BubbleFlight.crossFade)) {
            conversation.queue.drop()
        }
    }
}
