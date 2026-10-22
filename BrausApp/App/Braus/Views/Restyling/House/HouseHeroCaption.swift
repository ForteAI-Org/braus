//
//  HouseHeroCaption.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseHeroCaption is the text in the hero's glass capsule: the worker's name over its subtitle.
///
/// A change of either writes in as a reply does: the shown words fade out over
/// `HouseSwitch.captionFade`, then the new ones fade in from blurred, `RestylingTiming.wordStagger`
/// apart (`WordFade`), the subtitle's after the name's, while the capsule's width
/// springs to them. A caption that takes over another worker's capsule starts from that worker's
/// words, so the capsule itself never changes. Under Reduce Motion the words cross-fade and the
/// width changes while they are hidden. Outside a write the words are plain texts, so a caption at
/// rest is one text a line.
struct HouseHeroCaption: View {
    let words: Words

    /// What hovering the name tells.
    let help : String

    /// The words the caption shows, which follow `words` once written.
    @State private var shown: Words

    /// How far the shown words have faded in, in seconds of `WordFade`.
    @State private var elapsed = Double.infinity

    @State private var opacity = 1.0

    /// Whether words are being written, so each line shows through `WordFade`.
    @State private var isWriting = false

    /// The words being written, cancelled by newer ones.
    @State private var writing: Task<Void, Never>?

    /// Words are a caption's name and subtitle.
    struct Words: Equatable {
        let name    : String
        let activity: String
    }

    init(
        _ words      : Words,
        help         : String,
        from previous: Words?
    ) {
        self.words = words
        self.help  = help
        _shown     = State(initialValue: previous ?? words)
    }

    var body: some View {
        VStack(spacing: 1) {
            line(
                shown.name,
                font   : .systemFont(
                    ofSize: 13,
                    weight: .semibold
                ),
                elapsed: elapsed
            )
            .font(.system(
                size  : 13,
                weight: .semibold
            ))
            .lineLimit(1)
            .contentTransition(.identity)
            .help(help)
            line(
                shown.activity,
                font   : .systemFont(ofSize: 10.5),
                elapsed: elapsed - nameDuration
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.identity)
        }
        .opacity(opacity)
        .onAppear { write(words) }
        .onChange(of: words) { write(words) }
    }

    /// One line of the caption: its words fading in while they are written, one plain text otherwise.
    @ViewBuilder
    private func line(
        _ text : String,
        font   : NSFont,
        elapsed: Double
    ) -> some View {
        if isWriting {
            WordFade(
                text   : text,
                font   : font,
                elapsed: elapsed
            )
        } else {
            Text(verbatim: WordFade.line(text))
        }
    }

    /// How long the shown name takes to start its last word, after which the subtitle starts.
    private var nameDuration: Double {
        Double(shown.name.split(separator: " ").count) * RestylingTiming.wordStagger
    }

    /// Fades the shown words out and writes `next` in, unless it is already shown.
    private func write(_ next: Words) {
        guard next != shown else { return }

        writing?.cancel()
        writing = Task { @MainActor in
            let reduces = RestylingMotion.reducesMotion
            // The words go through `WordFade` before `elapsed` is reset, so they animate from zero.
            isWriting = !reduces
            withAnimation(.easeOut(duration: HouseSwitch.captionFade)) { opacity = 0 }
            try? await Task.sleep(for: .seconds(HouseSwitch.captionFade))
            guard !Task.isCancelled else { return }

            withTransaction(Transaction(animation: reduces ? nil : HouseSwitch.captionResize)) {
                shown = next
            }
            var cut = Transaction()
            cut.disablesAnimations = true
            withTransaction(cut) {
                elapsed = reduces ? .infinity : 0
                if !reduces { opacity = 1 }
            }
            if reduces {
                withAnimation(.easeIn(duration: HouseSwitch.captionFade * 2)) { opacity = 1 }
            } else {
                let duration = nameDuration + WordFade.duration(of: next.activity)
                withAnimation(.linear(duration: duration)) { elapsed = duration }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                // Every word shows whole by now, so the plain texts look the same.
                isWriting = false
            }
        }
    }
}
