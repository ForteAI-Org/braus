//
//  WordFade.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// WordFade shows one line of text whose words fade in: each from transparent, blurred and a little
/// low to itself, over `wordDuration`, each word `RestylingTiming.wordStagger` after the one before.
/// SwiftUI animates `elapsed`, as Core Animation cannot reach a text's words. The text takes the
/// font, colour and line limit around it; `font` is that font, which places the words.
///
/// Each word is the whole line masked to that word, from the middle of the space before it to the
/// middle of the space after it, faded through its view's opacity, blur and offset, which Core
/// Animation draws; whole, the words are the plain line, pixel for pixel. A text renderer would draw
/// the same, but it brings in SwiftUI's RenderBox, whose surface pool then wakes at every frame the
/// window draws, for the rest of the process.
struct WordFade: View {
    let text: String

    /// The font the text shows in, which measures where its words are.
    let font: NSFont

    /// How long the first word has been fading in, in seconds.
    var elapsed: Double

    /// How long one word takes to fade in.
    static let wordDuration = 0.35

    /// How long `text` takes to show entirely.
    static func duration(of text: String) -> Double {
        Double(max(0, words(in: text).count - 1)) * RestylingTiming.wordStagger + wordDuration
    }

    var body: some View {
        let line  = Self.line(text)
        let spans = Self.spans(
            of: text,
            in: font
        )
        ZStack {
            // An empty line keeps a line's height, as the plain text does.
            if spans.isEmpty { Text(verbatim: line) }
            ForEach(
                spans.indices,
                id: \.self
            ) { index in
                Text(verbatim: line)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: spans[index].upperBound - spans[index].lowerBound)
                            .offset(x: spans[index].lowerBound)
                    }
                    .modifier(Step(
                        elapsed: elapsed,
                        start  : Double(index) * RestylingTiming.wordStagger
                    ))
                    .transition(.identity)
            }
        }
    }

    /// `text` as its words show it: one space between two words, none at either end.
    static func line(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }

    /// Where each word of `text` lies along its line in `font`, from the middle of the space before it
    /// to the middle of the space after it; the first and the last run on past the line's ends.
    static func spans(
        of text: String,
        in font: NSFont
    ) -> [Range<CGFloat>] {
        let words = words(in: text)
        let space = width(
            of: " ",
            in: font
        )
        let reach: CGFloat = 10_000
        var spans: [Range<CGFloat>] = []
        var start = -reach
        for index in words.indices {
            let isLast = index == words.count - 1
            let end    = isLast ? reach : width(
                of: words[...index].joined(separator: " "),
                in: font
            ) + space / 2
            spans.append(start..<end)
            start = end
        }
        return spans
    }

    private static func width(
        of text: String,
        in font: NSFont
    ) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func words(in text: String) -> [Substring] {
        text.split(separator: " ")
    }

    /// Step is one word at `elapsed`, which starts fading in at `start`.
    struct Step: ViewModifier, Animatable {
        var elapsed: Double
        let start  : Double

        var animatableData: Double {
            get { elapsed }
            set { elapsed = newValue }
        }

        /// How far the word has faded in, from 0 to 1.
        var progress: Double {
            min(1, max(0, (elapsed - start) / WordFade.wordDuration))
        }

        func body(content: Content) -> some View {
            content
                .opacity(progress)
                .blur(radius: (1 - progress) * 4)
                .offset(y: (1 - progress) * 3)
        }
    }
}
