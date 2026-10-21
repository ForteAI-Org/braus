//
//  HouseLiveFlights.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI

/// HouseLiveFlights flies the new look's messages over the team's conversation, as `BubbleFlight`
/// flies the mockup's: a sent message from the composer's field into its bubble; a message sent
/// during a turn into the queue strip; a queued message from the strip into the transcript when the
/// turn ends or on Send Now; a replied bubble into the quote strip, and back when the quote goes.
///
/// A flight starts on what the field drew and ends on what the transcript draws: the transcript
/// lays the sent message's row out hidden (`TranscriptController.holdNextSent()`), scrolls to its
/// end first when the person had scrolled up, and the flight springs onto a picture of the bubble,
/// so the bubble shown as it lands is the one it already was. Only frames move; no text is scaled.
/// Under Reduce Motion nothing travels: the text fades where it was while its bubble or the strip's
/// line fades in. A flight whose bubble never comes fades where it waits (`patience`).
@MainActor
@Observable
final class HouseLiveFlights {

    /// The queue strip's line is laid out but not drawn while a flight carries its text in or out.
    private(set) var hidesQueueLine = false

    /// The quote strip's line is laid out but not drawn while the quote's flight carries it in.
    private(set) var hidesQuoteLine = false

    /// The composer's field, which a sent message flies from.
    @ObservationIgnored let field = ComposerField.Link()

    /// Where the strips' lines are in `BubbleFlight.space`, as the strips report them.
    @ObservationIgnored var queueLine = CGRect.zero
    @ObservationIgnored var quoteLine = CGRect.zero

    /// The transcript the flights land in, set by `attach(_:to:)`.
    @ObservationIgnored private(set) weak var transcript: TranscriptController?

    /// The stage the flights fly on, and the quote's flights, shared with the mockup.
    @ObservationIgnored private let bubbles = BubbleFlight()

    /// Flights waiting for their message's row, oldest first, and those waiting for the queue strip.
    @ObservationIgnored private var landings: [LiveFlight] = []
    @ObservationIgnored private var glides  : [LiveFlight] = []

    /// The next message to leave the queue is the person's removal or edit, not a send.
    @ObservationIgnored private var expectsRemoval = false

    /// The conversation whose queue the strip shows.
    @ObservationIgnored private var queueConversation: UUID?

    /// Flights still at the composer's field, which keeps its placeholder away meanwhile.
    @ObservationIgnored private var departures = 0

    /// The longest a flight waits for its bubble or its strip before it fades where it is.
    static let patience = 2.0

    /// The view that holds the flights, to lay over the conversation in `BubbleFlight.space`.
    var overlay: some View {
        bubbles.overlay
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The layer-hosting view the flights fly in, which `overlay` lays over the conversation.
    var stage: BubbleFlight.Stage { bubbles.overlay.stage }

    /// Lands flights in `transcript`, which offers Reply beside its bubbles, for `conversation`;
    /// whatever was in the air for another conversation fades.
    func attach(
        _ transcript   : TranscriptController,
        to conversation: UUID
    ) {
        (landings + glides).forEach { leave($0) }
        landings = []
        glides   = []
        self.transcript?.releaseHolds()
        self.transcript = transcript
        transcript.releaseHolds()
        transcript.showsReplyButtons = true
        transcript.onHeldArrival     = { [weak self] id in self?.arrived(id) }
        queueConversation = conversation
        expectsRemoval    = false
        hidesQueueLine    = false
        hidesQuoteLine    = false
    }

    // MARK: Sending

    /// Sets off the draft's flight from the composer's field as it is sent: into the transcript, or
    /// into the queue strip while the worker answers, where it is the shown line when `leadsQueue`.
    /// Called while the field still shows the draft.
    func depart(
        queued    : Bool,
        leadsQueue: Bool
    ) {
        guard let view = field.view, let typed = Self.picture(of: view), let flight = LiveFlight(
            typed    : typed,
            at       : stage.convert(view.convert(view.bounds, to: nil), from: nil),
            textInset: CGPoint(x: 0, y: view.textView.textContainerInset.height),
            fromField: true,
            on       : stage
        ) else { return }

        departures += 1
        showsPlaceholder()
        if queued {
            if leadsQueue { hidesQueueLine = true }
            glides.append(flight)
        } else if let transcript, transcript.showsNewest {
            landings.append(flight)
            transcript.holdNextSent()
        } else {
            // The newest messages are not loaded: the transcript opens at its end, the text fades.
            transcript?.scrollToBottom()
            leave(flight)
            return
        }
        expire(flight)
    }

    /// Lands the oldest waiting flight on `messageID`'s row, which the transcript holds, and draws
    /// the row once the flight is there.
    private func arrived(_ messageID: UUID) {
        guard !landings.isEmpty, let transcript else {
            transcript?.release(message: messageID)
            return
        }

        let flight = landings.removeFirst()
        guard let bubble = transcript.bubble(ofMessage: messageID) else {
            transcript.release(message: messageID)
            leave(flight)
            return
        }

        lifted(flight)
        flight.land(
            on   : LiveFlight.Landing(
                surface   : stage.convert(bubble.surface, from: nil),
                frame     : stage.convert(bubble.frame, from: nil),
                textOrigin: stage.convert(bubble.textOrigin, from: nil),
                image     : bubble.image
            ),
            color: personBubble
        ) { [weak transcript] in
            transcript?.release(message: messageID)
        }
    }

    /// The person's bubble colour as the transcript draws it in the stage's appearance.
    private var personBubble: CGColor {
        var color = NSColor.controlAccentColor.cgColor
        stage.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = TranscriptColors.personBubble.cgColor
        }
        return color
    }

    // MARK: The queue

    /// Follows the open conversation's queue: a message that joined it brings the oldest waiting
    /// flight into the strip; one that left it, not taken out by the person, flies from the strip
    /// into the transcript, as the end of a turn or Send Now sends it.
    func queueChanged(
        from old       : [QueuedMessage],
        to new         : [QueuedMessage],
        in conversation: UUID?
    ) {
        guard conversation == queueConversation else { return }

        if new.count > old.count, !glides.isEmpty {
            let flight = glides.removeFirst()
            // A turn later, once the strip has laid out its line.
            DispatchQueue.main.async { [weak self] in self?.glide(flight) }
        } else if new.count < old.count {
            guard !expectsRemoval else {
                expectsRemoval = false
                return
            }
            let index = old.indices.first { $0 >= new.count || old[$0] != new[$0] } ?? 0
            dequeue(old[index].excerpt)
        }
    }

    /// The next message to leave the queue is one the person removes or takes back to edit.
    func expectRemoval() {
        expectsRemoval = true
    }

    private func glide(_ flight: LiveFlight) {
        lifted(flight)
        flight.glide(to: queueLine) { [weak self] in self?.showQueueLine() }
    }

    /// Flies `text`, the queue strip's line, into the transcript as its message arrives.
    private func dequeue(_ text: String) {
        guard let transcript, transcript.showsNewest,
              let scale = stage.window?.backingScaleFactor,
              let typed = BubbleFlight.image(
                  of     : BubbleFlight.stripLine(text),
                  width  : queueLine.width,
                  scale  : scale,
                  isWhite: false
              ),
              let flight = LiveFlight(
                  typed    : typed,
                  at       : CGRect(
                      origin: queueLine.origin,
                      size  : typed.size
                  ),
                  textInset: .zero,
                  fromField: false,
                  on       : stage
              )
        else { return }

        hidesQueueLine = true
        landings.append(flight)
        transcript.holdNextSent()
        expire(flight)
    }

    /// Fades the queue strip's line in.
    private func showQueueLine() {
        withAnimation(.easeOut(duration: BubbleFlight.crossFade)) { hidesQueueLine = false }
    }

    // MARK: The quote

    /// Quotes `quote` in the next message: a copy of its bubble flies into the quote strip, whose
    /// line shows once it is there. Under Reduce Motion, or with the bubble off screen, the strip
    /// only comes.
    func reply(
        _ quote: MessageQuote,
        in team: TeamModel
    ) {
        let bubble = RestylingMotion.reducesMotion ? nil : transcript?.bubble(ofMessage: quote.messageID)
        hidesQuoteLine  = bubble != nil
        team.draftQuote = quote
        guard let bubble else { return }

        let frame = stage.convert(bubble.frame, from: nil)
        // A turn later, once the strip has laid out its line.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            bubbles.quote(
                (bubble.image, frame.size),
                at        : .zero,
                fill      : nil,
                from      : frame,
                to        : quoteLine,
                lineText  : quote.excerpt
            ) { [weak self] in
                self?.hidesQuoteLine = false
            }
        }
    }

    /// Takes the draft's quote back: its line flies back into its bubble as the strip closes.
    func unquote(in team: TeamModel) {
        guard let quote = team.draftQuote else { return }

        hidesQuoteLine  = true
        team.draftQuote = nil
        bubbles.unquote(
            from    : quoteLine,
            lineText: quote.excerpt
        ) { [weak self] in
            guard let self, let surface = transcript?.frame(ofMessage: quote.messageID) else { return nil }

            return stage.convert(surface, from: nil)
        }
    }

    // MARK: Flights

    /// Fades `flight` where it waits when nothing came for it in time.
    private func expire(_ flight: LiveFlight) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
            guard let self, !flight.isLeaving else { return }

            if let index = landings.firstIndex(where: { $0 === flight }) {
                landings.remove(at: index)
                transcript?.cancelHold()
            }
            if let index = glides.firstIndex(where: { $0 === flight }) {
                glides.remove(at: index)
                showQueueLine()
            }
            leave(flight)
        }
    }

    private func leave(_ flight: LiveFlight) {
        lifted(flight)
        flight.vanish()
    }

    /// Counts `flight` off the field once it leaves it, and brings the strip's next line in after
    /// a queued message has lifted off it.
    private func lifted(_ flight: LiveFlight) {
        let delay = BubbleFlight.reflow.typedOut.end
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            if flight.fromField {
                departures = max(0, departures - 1)
                showsPlaceholder()
            } else {
                showQueueLine()
            }
        }
    }

    /// Keeps the field's placeholder away while a flight is still at it.
    private func showsPlaceholder() {
        field.view?.textView.hidesPlaceholder = departures > 0
    }

    /// What `field` shows, as it draws it, without the caret.
    private static func picture(of field: ComposerScrollView) -> (image: CGImage, size: CGSize)? {
        let carets = field.textView.subviews.filter { $0 is NSTextInsertionIndicator && !$0.isHidden }
        carets.forEach { $0.isHidden = true }
        defer { carets.forEach { $0.isHidden = false } }
        guard let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return nil }

        field.cacheDisplay(
            in: field.bounds,
            to: bitmap
        )
        return bitmap.cgImage.map { ($0, field.bounds.size) }
    }
}
