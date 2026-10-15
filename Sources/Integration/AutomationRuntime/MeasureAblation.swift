//
//  MeasureAblation.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import Foundation

/// MeasureAblation is the knowledge a measure turns off in one process, to attribute a difference to it: the control
/// without recall and the ablations of the Brain and of the Memory the live protocol compares a reuse with. It is no mode
/// of the product: `BRAUS_MEASURE_ABLATION` names it when a measure launches the process (`recall`, `brain`, or both,
/// separated by a comma), and nothing else sets it. Everything is still recorded and learned; only what the agent is shown
/// changes. With `recall`, every search answers that nothing fits, and its note, recorded with it, names the ablation.
/// With `brain`, scenes are shown as perceived, without the Brain's enrichment.
nonisolated public struct MeasureAblation: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let recall = MeasureAblation(rawValue: 1)
    public static let brain  = MeasureAblation(rawValue: 2)

    /// The environment variable a measure's launch sets.
    public static let variable = "BRAUS_MEASURE_ABLATION"

    /// What this process turns off, read once at launch.
    public static let launched = parse(ProcessInfo.processInfo.environment[variable])

    /// A test's ablation for the task it runs.
    @TaskLocal public static var testing: MeasureAblation?

    /// What is turned off now.
    public static var active: MeasureAblation { testing ?? launched }

    /// The ablation a variable's value names; an unknown word turns nothing off.
    public static func parse(_ value: String?) -> MeasureAblation {
        var found: MeasureAblation = []
        for word in (value ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            if word == "recall" { found.insert(.recall) }
            if word == "brain" { found.insert(.brain) }
        }
        return found
    }

    /// The note a search answers and records under the ablation of the Recall.
    public static let recallNote = "measure: the Recall is turned off in this process (BRAUS_MEASURE_ABLATION=recall); nothing was searched"
}
