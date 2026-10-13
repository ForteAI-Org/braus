//
//  RecallThirdReviewTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
@testable import Memory
import Testing

/// RecallThirdReviewTests are the third independent review's counterexamples of scope (F10, F11), with the review's bodies and
/// expectations unchanged.
@Suite("Third independent D3 review: scope and structural provenance")
struct RecallThirdReviewTests {
    typealias S = RecallSelectionTests

    @Test("An explicitly named producer does not authorize unrelated intervening work")
    func unrelatedWorkBetweenProducerAndConsumer() throws {
        let source = RecallProvenanceTests.twoReports(attachment: "task-rep/exported_report")
        let outcome = S.select([S.scored(source, steps: [2: 0.9, 3: 0.9, 4: 0.9, 5: 0.9], parts: ["rep/block-2": 0.95])],
                               need: "Email the report to luca@example.com",
                               values: [S.value("recipient", "luca@example.com")])
        let selected = try #require(outcome.selected)
        #expect(!selected.positions.contains(1),
                "The stated producer is the Pages export. The independent Safari download at position 1 is not requested or required")
    }

    @Test("A synonymous action omitted from a multi-action need must not produce complete coverage")
    func synonymousRotationMustNotDisappear() throws {
        let source = S.photo()
        let scored = S.scored(source, steps: [2: 0.91, 3: 0.91, 4: 0.91, 5: 0.91, 6: 0.91],
                              parts: ["photo/block-1": 0.95])
        let positive = S.select([scored], need: "Rotate the open image right and export it as PNG", app: S.preview)
        #expect(positive.selected?.positions == 2...6 && positive.coverage == .complete,
                "The same source contains the complete valid method")
        let paraphrase = S.select([scored], need: "Turn the open picture clockwise and export it as PNG", app: S.preview)
        #expect(paraphrase.coverage != .complete || paraphrase.selected?.positions.contains(2) == true,
                "A complete export alone does not cover the requested clockwise rotation")
    }
}

/// RecallScopeDependencyTests prove review F10 beyond the review's case: a producer is included only with the work its
/// dependency needs, in one application as across applications.
@Suite("A producer's dependency without the unrelated work between")
struct RecallScopeDependencyTests {
    typealias S = RecallSelectionTests

    /// In Safari: the report downloaded, an unrelated page opened, then the report uploaded through a sheet; the upload's file
    /// is the download's output, as the source's attempt stated.
    static func upload(stated: Bool = true, relatedBetween: Bool = false) -> RecallSource {
        let safari = RecallScopeSelectionTests.safari
        let steps = [
            S.step(0, part: "up", tool: .act, [("target", S.text("Download report")), ("verb", S.text("click"))], bundle: safari,
                   entry: .state("portal"), label: "Download the monthly report"),
            S.step(1, part: "up", tool: .act, [("target", S.text("News")), ("verb", S.text("click"))], bundle: safari,
                   entry: .state("portal"), exit: relatedBetween ? .state("upload") : .unknown, label: "Open the news page"),
            S.step(2, part: "up", tool: .act, [("target", S.text("Upload")), ("verb", S.text("click"))], bundle: safari,
                   entry: relatedBetween ? .state("upload") : .state("portal"), exit: .state("upload"), label: "Open the upload sheet"),
            S.step(3, part: "up", tool: .typeText, [("target", S.text("File")), ("text", .parameter("file"))], bundle: safari,
                   entry: .state("upload"), label: "Type <file> in the file field"),
            S.step(4, part: "up", tool: .press, [("button", S.text("Submit"))], bundle: safari, entry: .state("upload"),
                   exit: .state("portal"), label: "Submit the upload"),
        ]
        let parts: [RecallSource.Part] = [
            .init(partID: "up/procedure", kind: .procedure, firstPosition: 0, lastPosition: 4, label: "Download the report and upload it",
                  bundleID: safari, isOffered: true),
            .init(partID: "up/block-0", kind: .subprocedure, firstPosition: 0, lastPosition: 4, label: "Download the report and upload it",
                  bundleID: safari, isOffered: true),
        ] + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                          label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        let origins = stated ? [RecallSource.Origin(source: .previousOutput, reference: "report_file", attemptID: "attempt-up", taskID: "task-up",
                                                    value: "report.pdf")] : []
        return RecallSource(routeID: "up", procedureLabel: "Download the report and upload it", steps: steps, parts: parts, parameters: [
            .init(parameterID: "report", name: "report_file", role: "the report downloaded", kind: .file, direction: .output, unit: nil,
                  observedValues: ["report.pdf"], producedBy: "up/step-0"),
            .init(parameterID: "file", name: "file", role: "the file uploaded", kind: .file, direction: .input, unit: nil,
                  observedValues: ["report.pdf"], origins: origins),
        ], confirmedUses: 0)
    }

    static func uploading(_ source: RecallSource) -> NeedOutcome {
        S.select([S.scored(source, steps: [2: 0.8, 3: 0.8, 4: 0.8], parts: ["up/block-0": 0.7])], need: "Submit the upload of the report", values: [])
    }

    @Test("in one application: the upload alone, its file missing and its producer stated, the unrelated page left out")
    func unrelatedWorkInOneApplication() throws {
        let source = Self.upload()
        let outcome = Self.uploading(source)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 2...4, "\(selected.positions)")
        #expect(selected.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "file" })
        #expect(!selected.requirements.contains { $0.kind == .inputProduced })
        let file = try #require(source.parameters.first { $0.parameterID == "file" })
        #expect(source.feed(of: file)?.output.producedBy == "up/step-0")
    }

    @Test("work between them that belongs to the selection's episode is not unrelated: the producer and what joins it are included")
    func relatedWorkBetweenIsIncluded() throws {
        let outcome = Self.uploading(Self.upload(relatedBetween: true))
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 0...4, "\(selected.positions)")
        #expect(selected.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "file" && $0.stepPosition == 0 })
    }

    @Test("both ends named across a block of another application the need does not name: the later work alone, partial, the earlier said left out")
    func unnamedBlockBetweenNamedWork() throws {
        let source = RecallProvenanceTests.twoReports(attachment: "task-rep/exported_report")
        let outcome = S.select([S.scored(source, steps: [0: 0.8, 2: 0.8, 3: 0.8, 4: 0.8, 5: 0.8], parts: ["rep/procedure": 0.9])],
                               need: "Export the report as PDF and email it to luca@example.com",
                               values: [S.value("recipient", "luca@example.com")])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 2...5 && outcome.leftOut == 0...0, "\(selected.positions) \(String(describing: outcome.leftOut))")
        #expect(outcome.coverage == .partial && outcome.reason == .gaps)
        #expect(selected.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "attachment" })
    }

    @Test("a producer next to the selection is included; with no stated origin, none is")
    func adjacentAndUnstatedProducers() throws {
        let outcome = Self.uploading(Self.upload(stated: false))
        #expect(outcome.selected?.positions == 2...4 && outcome.coverage == .ambiguous)
        #expect(outcome.selected?.requirements.contains { $0.kind == .inputProduced } == false)
    }
}

/// RecallUnaccountedWorkTests prove the automatic selector's side of review F11: a clause whose verb the method does not know
/// leaves the need partial, the verb named; an object written otherwise does not.
@Suite("Work the automatic selector cannot account for")
struct RecallUnaccountedWorkTests {
    typealias S = RecallSelectionTests

    static let scored = S.scored(S.photo(), steps: [2: 0.91, 3: 0.91, 4: 0.91, 5: 0.91, 6: 0.91], parts: ["photo/block-1": 0.95])

    @Test("the paraphrase is partial and names the verb it cannot read; the original wording stays complete")
    func paraphraseNamesTheVerb() {
        let paraphrase = S.select([Self.scored], need: "Turn the open picture clockwise and export it as PNG", app: S.preview)
        #expect(paraphrase.coverage == .partial && paraphrase.reason == .gaps && paraphrase.unaccounted == ["turn"], "\(paraphrase.unaccounted)")
        let original = S.select([Self.scored], need: "Rotate the open image right and export it as PNG", app: S.preview)
        #expect(original.coverage == .complete && original.unaccounted.isEmpty)
    }

    @Test("an object written otherwise is no unaccounted work; an Italian verb is, and names nothing anyway")
    func objectsAndLanguages() {
        let photo = S.select([Self.scored], need: "Export the photo as PNG", app: S.preview)
        #expect(photo.coverage == .complete && photo.unaccounted.isEmpty, "\(photo.unaccounted)")
        let italian = S.select([Self.scored], need: "Ruota la foto ed esportala in PNG", app: S.preview)
        #expect(italian.selected == nil || italian.coverage != .complete)
    }
}
