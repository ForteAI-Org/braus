//
//  WordFade.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// WordFade draws each word of a text as it fades in: from transparent, blurred and a little low to
/// itself, over `wordDuration`, each word `RestylingTiming.wordStagger` after the one before.
/// SwiftUI animates `elapsed`, as Core Animation cannot reach a text's words.
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
