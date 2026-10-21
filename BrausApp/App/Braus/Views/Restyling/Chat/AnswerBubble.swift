//
//  AnswerBubble.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// AnswerBubble is one of the worker's messages: its tool line above, in plain words, and its
/// bubble on the leading side, which holds the thinking blob until the reply comes.
///
/// A reply that comes while the bubble is shown widens the bubble and fades its words in from
/// blurred, `RestylingTiming.wordStagger` apart; a reply already there when the bubble appears, or
/// any reply under Reduce Motion, shows at once. The tool line spins while its step runs and keeps
/// a quiet dot once done: a step that went wrong is never marked here.
struct AnswerBubble: View {
    let message : MockConversation.Message

    /// The reply button and frame keeping of the transcript, for the bubble once it has replied.
    let quotable: ChatTranscriptView.Quotable

    /// Whether this bubble has shown the blob, so its reply arrives while it is watched.
    @State private var hasThought = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            if let tool = message.tool {
                toolLine(tool)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            ChatTranscriptView.workerBubble(quotable: quotable) {
                if message.isThinking {
                    ThinkingBlob()
                        .frame(
                            width : 30,
                            height: 17
                        )
                } else {
                    Reply(
                        text   : message.text,
                        reveals: hasThought && !RestylingMotion.reducesMotion
                    )
                }
            }
        }
        .onAppear { if message.isThinking { hasThought = true } }
    }

    private func toolLine(_ tool: MockConversation.Tool) -> some View {
        HStack(spacing: 7) {
            if tool.isDone {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(
                        width : 12,
                        height: 12
                    )
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .frame(
                        width : 12,
                        height: 12
                    )
            }
            Text(tool.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(
            .leading,
            4
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Reply

    /// Reply is the reply's text; when `reveals`, its words fade in from blurred, one after
    /// another, as it appears.
    private struct Reply: View {
        let text   : String
        let reveals: Bool

        @State private var elapsed: Double?

        var body: some View {
            (reveals ? WordFade.text(text) : Text(text))
                .font(.system(size: 14))
                .lineSpacing(3)
                .textRenderer(WordFade(elapsed: elapsed ?? .infinity))
                .textSelection(.enabled)
                .onAppear {
                    guard reveals else { return }

                    elapsed = 0
                    withAnimation(.linear(duration: WordFade.duration(of: text))) {
                        elapsed = WordFade.duration(of: text)
                    }
                }
        }
    }

    /// WordFade draws each word of a text as it fades in: from transparent, blurred and a little
    /// low to itself, over `wordDuration`, each word `RestylingTiming.wordStagger` after the one
    /// before. SwiftUI animates `elapsed`, as Core Animation cannot reach a text's words.
    struct WordFade: TextRenderer, Animatable {
        var elapsed: Double

        var animatableData: Double {
            get { elapsed }
            set { elapsed = newValue }
        }

        /// How long one word takes to fade in.
        static let wordDuration = 0.35

        /// How long `text` takes to show entirely.
        static func duration(of text: String) -> Double {
            Double(max(0, words(in: text).count - 1)) * RestylingTiming.wordStagger + wordDuration
        }

        /// `text` with each word marked with its place, as one text that breaks as `text` does.
        static func text(_ text: String) -> Text {
            words(in: text)
                .enumerated()
                .reduce(Text(verbatim: "")) { sentence, word in
                    let marked = Text(verbatim: String(word.element))
                        .customAttribute(Word(index: word.offset))
                    return word.offset == 0
                        ? marked
                        : Text("\(sentence) \(marked)")
                }
        }

        func draw(
            layout    : Text.Layout,
            in context: inout GraphicsContext
        ) {
            for line in layout {
                for run in line {
                    let start    = Double(run[Word.self]?.index ?? 0) * RestylingTiming.wordStagger
                    let progress = min(1, max(0, (elapsed - start) / Self.wordDuration))
                    guard progress < 1 else {
                        context.draw(run)
                        continue
                    }

                    var word = context
                    word.opacity = progress
                    word.addFilter(.blur(radius: (1 - progress) * 4))
                    word.translateBy(
                        x: 0,
                        y: (1 - progress) * 3
                    )
                    word.draw(run)
                }
            }
        }

        private static func words(in text: String) -> [Substring] {
            text.split(separator: " ")
        }

        /// Word marks the run of one word with its place in the reply.
        struct Word: TextAttribute {
            let index: Int
        }
    }

    // MARK: Thinking blob

    /// ThinkingBlob is the transcript's thinking indicator, `ThinkingBlobView`, in the bubble's
    /// light grey; it animates itself in Core Animation and stops when hidden.
    private struct ThinkingBlob: NSViewRepresentable {

        func makeNSView(context: Context) -> ThinkingBlobView {
            let view = ThinkingBlobView()
            view.tint = NSColor(white: 0.92, alpha: 1)
            return view
        }

        func updateNSView(
            _ view : ThinkingBlobView,
            context: Context
        ) {}
    }
}
