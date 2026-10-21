//
//  MockConversation.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation
import Observation

/// MockConversation is the mockup's conversation with one worker: its messages, starting from a
/// short sample, and a simulated turn of the worker's after each message the person sends.
///
/// A turn starts when the person sends (`isAnswering`), and the worker answers once the message
/// has landed (`answer(then:)`): it reads, thinks in a bubble while a tool line above it says what
/// it does, then replies. What the person sends meanwhile waits in `queue`; at the end of the turn
/// the caller sends the oldest (`sendQueued()`), and Send Now stops the turn for the shown one
/// (`sendNow()`). The next message the person sends quotes `quote`.
@MainActor
@Observable
final class MockConversation {

    /// Message is one entry of the transcript: the person's text, with the passage it quotes, or
    /// the worker's, with the tool line above it, thinking until its reply comes.
    struct Message: Identifiable, Equatable {
        enum Author: Equatable {
            case person
            case worker
        }

        let id        : UUID
        let author    : Author
        var text      : String
        var tool      : Tool?
        var quote     : String?
        var isThinking: Bool

        init(
            _ author  : Author,
            _ text    : String,
            tool      : Tool? = nil,
            quote     : String? = nil,
            isThinking: Bool = false
        ) {
            id              = UUID()
            self.author     = author
            self.text       = text
            self.tool       = tool
            self.quote      = quote
            self.isThinking = isThinking
        }
    }

    /// Tool is the line above a worker's reply: what it does, or did, in plain words.
    struct Tool: Equatable {
        var text  : String
        var isDone: Bool
    }

    /// Phase is what the worker does in a turn: reading the message, then working on it.
    enum Phase: Equatable {
        case idle
        case reading
        case working
    }

    var messages: [Message]

    /// Whether a turn runs, from the moment the person sends until the worker has replied.
    private(set) var isAnswering = false

    private(set) var phase = Phase.idle

    /// How many turns the worker has started answering, for the hero to prepare at each.
    private(set) var turns = 0

    /// The message the next one the person sends quotes.
    var quote: Message?

    var queue = MessageQueue()

    private var turn: Task<Void, Never>?

    private var replies = 0

    /// The worker's name, before its words in a quote.
    private let workerName: String

    init(
        workerName: String,
        messages  : [Message] = MockConversation.sample
    ) {
        self.workerName = workerName
        self.messages   = messages
    }

    /// Sends `text`: at the foot of the transcript, with the quote, starting a turn, and returned;
    /// into the queue while a turn runs, returning nil.
    @discardableResult
    func send(_ text: String) -> Message? {
        guard !isAnswering else {
            queue.add(text)
            return nil
        }

        let message = Message(
            .person,
            text,
            quote: quote.map(quoting)
        )
        quote       = nil
        isAnswering = true
        messages.append(message)
        return message
    }

    /// Stops the turn and sends the queued message the strip shows.
    func sendNow() -> Message? {
        guard let text = queue.sendNow() else { return nil }

        stopTurn()
        return start(text)
    }

    /// At the end of a turn, sends the oldest queued message, if any.
    func sendQueued() -> Message? {
        guard !isAnswering, let text = queue.endOfTurn() else { return nil }

        return start(text)
    }

    /// Plays the worker's answer to the message that has just landed, then calls `endOfTurn`
    /// unless the turn was stopped.
    func answer(then endOfTurn: @escaping @MainActor () -> Void) {
        turn?.cancel()
        let reply = Self.replies[replies % Self.replies.count]
        replies += 1
        turn = Task { [weak self] in
            guard let self else { return }

            phase  = .reading
            turns += 1
            guard await pause(0.45) else { return }

            let thinking = Message(
                .worker,
                "",
                isThinking: true
            )
            let id       = thinking.id
            messages.append(thinking)
            phase = .working
            for (delay, text) in Self.tools {
                guard await pause(delay) else { return }

                update(id) { $0.tool = Tool(text: text, isDone: false) }
            }
            guard await pause(1.4) else { return }

            update(id) {
                $0.tool       = Tool(text: Self.toolDone, isDone: true)
                $0.text       = reply
                $0.isThinking = false
            }
            let words = reply.split(separator: " ").count
            guard await pause(Double(words) * RestylingTiming.wordStagger + 0.4) else { return }

            isAnswering = false
            phase       = .idle
            turn        = nil
            endOfTurn()
        }
    }

    /// Stops the running turn; a worker still thinking says nothing.
    func stopTurn() {
        turn?.cancel()
        turn = nil
        messages.removeAll { $0.isThinking }
        isAnswering = false
        phase       = .idle
    }

    private func start(_ text: String) -> Message {
        let message = Message(
            .person,
            text
        )
        isAnswering = true
        messages.append(message)
        return message
    }

    private func update(
        _ id  : UUID,
        _ edit: (inout Message) -> Void
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

        edit(&messages[index])
    }

    /// Waits `seconds`; false when the turn was cancelled meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    /// The quote a reply to `message` carries: the worker's name before a worker's words.
    private func quoting(_ message: Message) -> String {
        message.author == .worker ? "\(workerName): \(message.text)" : message.text
    }

    /// The tool line's steps while the worker works: each after its delay, in seconds.
    private static let tools = [
        (1.05, "Opens Pro Tools"),
        (1.3, "Exports the stems"),
    ]

    private static let toolDone = "Exported 12 stems"

    private static let replies = [
        "All right. I’m opening the session and exporting the stems as WAV, 48 kHz, one file per track.",
        "Done with this too: 12 stems in the Delivery/Stems folder. Shall I zip them?",
        "Got it, I’ll add it to the run.",
    ]

    static let sample: [Message] = [
        Message(
            .person,
            "Export the open Pro Tools session as an AAF into the Delivery folder."
        ),
        Message(
            .worker,
            "I’m checking the session, exporting the AAF, and I’ll confirm the delivery.",
            tool: Tool(
                text  : "Opened Pro Tools and read the session",
                isDone: true
            )
        ),
        Message(
            .worker,
            "The dialog has a preset I don’t know. Keep it, or use stereo interleaved?"
        ),
        Message(
            .person,
            "Stereo interleaved."
        ),
    ]
}
