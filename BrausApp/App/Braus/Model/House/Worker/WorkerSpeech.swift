//
//  WorkerSpeech.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation

/// WorkerSpeech is what a worker says over its mascot in its screen window (`ScreenWorkerPresence`):
/// thinking while its turn runs with no tool call under way, acting while one is, in the words of
/// the conversation's tool line (`TranscriptWording.toolStep`), and saying the first line of what it
/// ended its last turn on, until the person writes to it again. Nil while it has nothing under way
/// and nothing to say.
nonisolated enum WorkerSpeech: Equatable, Sendable {
    case thinking
    case acting(String)
    case saying(String)

    /// Report is what a worker's latest turn reported as it ran (`TeamModel.turnReports`): its tool
    /// records so far, and the block it wrote last while no tool record has come after it.
    struct Report: Equatable, Sendable {
        private(set) var tools: [String] = []
        var lastWords         : String?

        /// A tool record: the block before it introduced the call, so the turn has no last words yet.
        mutating func add(tool record: String) {
            tools.append(record)
            lastWords = nil
        }
    }

    /// What a worker says with `report` from its latest turn: while `isAnswering`, acting while the
    /// last of its tool steps waits for its result and thinking otherwise; after the turn, saying the
    /// first line of the words it ended on, or nothing.
    init?(
        report     : Report?,
        isAnswering: Bool
    ) {
        if isAnswering {
            let step = ToolStep.steps(from: report?.tools ?? []).last { !$0.isNote }
            if let step, step.state == .pending {
                self = .acting(TranscriptWording.toolStep(
                    step,
                    ending: nil
                ))
            } else {
                self = .thinking
            }
            return
        }
        guard let line = report?.lastWords.flatMap(Self.firstLine) else { return nil }

        self = .saying(line)
    }

    /// The first line of `text` with words in it, without the Markdown marks that would show as
    /// themselves on one line; nil when there is none.
    static func firstLine(of text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { line in
                ["**", "`"].reduce(String(line)) { text, mark in
                    text.replacingOccurrences(
                        of  : mark,
                        with: ""
                    )
                }
            }
            .map { text -> Substring in
                // A heading's or a quote's marks, then a list item's.
                let line = text.drop { "#> \t".contains($0) }
                return line.hasPrefix("- ") || line.hasPrefix("* ") ? line.dropFirst(2) : line
            }
            .first { !$0.allSatisfy(\.isWhitespace) }
        return line.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }
}
