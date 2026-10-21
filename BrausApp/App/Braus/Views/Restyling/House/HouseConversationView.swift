//
//  HouseConversationView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseConversationView is the conversation with the chosen worker: the worker at the top centre,
/// the transcript under it, and the composer floating over the transcript's foot.
///
/// A message the person sends flies from the composer's field into its bubble at the transcript's
/// foot (`BubbleFlight`), while the transcript makes room for it with the flight's spring; the
/// bubble is drawn once the flight lands, and the worker answers it. A transcript scrolled up first
/// scrolls to its end, and only then takes the message, so the flight knows where it lands. What
/// the person sends while the worker answers flies into the queue strip above the composer instead;
/// at the end of the turn, or on Send Now, a queued message flies from the strip into the transcript.
///
/// A change of worker plays `HouseSwitch`: the worker comes in on its own beats, the transcript fades
/// in over the leaving one, and the composer stands still. A leaving conversation hides its composer
/// at once and gives up the window's focus, so the arriving composer alone can take the keyboard.
struct HouseConversationView: View {
    let worker           : MockWorker
    let isComposerFocused: FocusState<Bool>.Binding

    /// Whether another worker's conversation is taking this one's place.
    @Environment(\.houseSwitchLeaving) private var isLeaving

    /// Whether the conversation has appeared, which brings its worker and its transcript in.
    @State private var hasAppeared = false

    /// The focus a leaving composer holds instead of the window's.
    @FocusState private var leavingFocus: Bool

    @State private var conversation: MockConversation

    @State private var flight = BubbleFlight()

    /// The messages whose flight has not landed yet, laid out but not drawn.
    @State private var landing: Set<MockConversation.Message.ID> = []

    /// What the person is writing in the composer.
    @State private var draft = ""

    /// Whether a sent text is still leaving the composer's field, which hides its placeholder.
    @State private var isDeparting = false

    /// The composer field's width, which, with the draft, gives its height.
    @State private var fieldWidth: CGFloat = 0

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

    /// Where the transcript is scrolled, which a send brings to its end.
    @State private var position = ScrollPosition(edge: .bottom)

    /// Whether the transcript shows its end.
    @State private var isAtEnd = true

    /// What waits for the transcript to show its end, run when it does.
    @State private var atEndActions: [() -> Void] = []

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
                preparation: conversation.turns,
                action     : conversation.action,
                stage      : stage
            )
            .padding(
                .top,
                6
            )
            ChatTranscriptView(
                messages      : conversation.messages,
                landing       : landing,
                frames        : frames,
                position      : $position,
                onLandingFrame: land,
                onColumnWidth : { columnWidth = $0 },
                onAtEnd       : reached,
                onReply       : reply
            )
            .opacity(stage == .present ? 1 : 0)
            .animation(
                .easeInOut(duration: HouseSwitch.crossFade),
                value: stage
            )
            // The composer and its strips float over the transcript, which scrolls under them to the
            // window's edge and keeps its last message clear of them.
            .safeAreaInset(
                edge   : .bottom,
                spacing: 0
            ) {
                dock
            }
        }
        // The composer grows and shrinks a line at a time, a strip comes and goes above it, and the
        // transcript gives way, together.
        .animation(
            BubbleFlight.transcriptAnimation,
            value: HouseComposerField.height(
                of   : draft,
                width: fieldWidth
            )
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
        .allowsHitTesting(!isLeaving)
        .accessibilityHidden(isLeaving)
        .onAppear { hasAppeared = true }
    }

    /// Where the conversation is in a change of worker.
    private var stage: HouseSwitch.Stage {
        if isLeaving { return .leaving }
        return hasAppeared ? .present : .arriving
    }

    /// The composer with the strips joined above it, floating on the conversation's ground: solid
    /// behind them and fading to clear over `HouseFoot.fadeHeight` above, as the sidebar's foot does,
    /// so a message passing under dissolves with no edge. Its top is where the transcript's last
    /// message rests, which an unanimated marker there reports as the layout's final frame while the
    /// composer and the transcript animate toward it.
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
                    title      : quote.author == .worker ? "Reply to \(worker.name)" : "Reply",
                    text       : quote.text,
                    hidesText  : isQuoteLanding,
                    onTextFrame: { quoteLine = $0 },
                    onRemove   : unquote
                )
                .transition(.opacity)
            }
            HouseComposer(
                worker      : worker,
                text        : $draft,
                isFocused   : isLeaving ? $leavingFocus : isComposerFocused,
                isDeparting : isDeparting,
                onFieldWidth: { fieldWidth = $0 },
                onSend      : send
            )
        }
        .frame(maxWidth: ChatTranscriptView.columnWidth)
        .padding(
            .horizontal,
            24
        )
        .padding(
            .top,
            HouseFoot.fadeHeight
        )
        .padding(
            .bottom,
            20
        )
        .frame(maxWidth: .infinity)
        .background { ground }
        // The arriving composer stands in the same place, so the leaving one goes at once.
        .opacity(isLeaving ? 0 : 1)
        .animation(
            nil,
            value: isLeaving
        )
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .transaction { $0.animation = nil }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(BubbleFlight.space)).minY
                } action: { minY in
                    foot = minY
                }
        }
    }

    /// The floating composer's ground, the conversation's colour.
    private var ground: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors    : [Color("RestylingGround").opacity(0), Color("RestylingGround")],
                startPoint: .top,
                endPoint  : .bottom
            )
            .frame(height: HouseFoot.fadeHeight)
            .allowsHitTesting(false)
            Color("RestylingGround")
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
        let origin = BubbleFlight.Origin.field(
            field,
            scroll: scroll
        )
        isDeparting = true
        // A queued text the strip will show waits for its flight there, unanimated, whatever
        // animates around it; behind others, it flies to the strip and fades over the shown one.
        if conversation.isAnswering, conversation.queue.items.isEmpty { isQueueLanding = true }
        let message = withAnimation(BubbleFlight.transcriptAnimation) {
            conversation.compose(text)
        }
        if let message {
            fly(
                message,
                from: origin
            )
        } else {
            queue(
                text,
                from: origin
            )
        }
    }

    /// Carries `text`, just queued, from the composer's field into the strip's line, which shows it
    /// once it is there when it is the message that goes next.
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
        departed()
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

    /// Starts `message`'s flight from `origin`, where its text was, then, once the transcript shows
    /// its end, lays the message out hidden at its foot, with room made for it.
    private func fly(
        _ message: MockConversation.Message,
        from origin: BubbleFlight.Origin
    ) {
        flight.launch(
            message.id,
            text  : message.text,
            quote : message.quote,
            from  : origin,
            column: columnWidth
        )
        reachEnd {
            withAnimation(BubbleFlight.transcriptAnimation) {
                landing.insert(message.id)
                conversation.post(message)
            }
            departed()
        }
    }

    /// Shows the field's placeholder again once a text that left it has lifted clear of it.
    private func departed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + BubbleFlight.crossFade) {
            isDeparting = false
        }
    }

    /// Brings the transcript to its end, when it is scrolled up, then runs `action`: a quick native
    /// scroll, or a jump under Reduce Motion. A scroll is no animation SwiftUI reports the end of,
    /// so `action` waits for the transcript to show its end, or at most `scrollToEndLimit`.
    private func reachEnd(then action: @escaping () -> Void) {
        guard !isAtEnd else {
            action()
            return
        }

        atEndActions.append(action)
        if RestylingMotion.reducesMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(.smooth(duration: Self.scrollToEnd)) {
                position.scrollTo(edge: .bottom)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollToEndLimit) {
            runAtEndActions()
        }
    }

    /// Keeps whether the transcript shows its end, and runs what waits for it once it does.
    private func reached(end isAtEnd: Bool) {
        self.isAtEnd = isAtEnd
        if isAtEnd { runAtEndActions() }
    }

    private func runAtEndActions() {
        let actions = atEndActions
        atEndActions = []
        actions.forEach { $0() }
    }

    /// The longest a send waits for the transcript to reach its end.
    private static let scrollToEndLimit = 0.8

    /// How long a transcript scrolled up takes to reach its end before a send.
    private static let scrollToEnd = 0.3

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
        let message = withAnimation(BubbleFlight.transcriptAnimation) {
            conversation.sendQueued()
        }
        guard let message else { return }

        leaveQueue(
            message,
            from: line
        )
    }

    /// Stops the turn and sends the queued message the strip shows.
    private func sendNow() {
        let line = queueLine
        isQueueLanding = true
        let message = withAnimation(BubbleFlight.transcriptAnimation) {
            conversation.sendNow()
        }
        guard let message else { return }

        leaveQueue(
            message,
            from: line
        )
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
