//
//  RecallSecondReviewTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
import EngineCore
@testable import Memory
import Testing

/// RecallSecondReviewTests keep the second independent review's counterexamples as the review wrote them, with their
/// expectations unchanged: a row template that does not prove the record the task asks for, nor bind an unresolved
/// one; an integer parameter confirmed by its integer argument; equal historical values that do not make a folder
/// the producer of an unrelated note title. Each call and step names a valid application and state.
@Suite("The second review's counterexamples: bindings and dependency evidence")
struct RecallSecondReviewTests {
    typealias S = RecallSelectionTests
    static let app = "com.example.Editor"

    static func targetStep() -> RecallSource.Step {
        S.step(0, tool: .act, [("target", .parameter("record")), ("verb", S.text("click"))], bundle: app,
               entry: .state("main"), elementKey: "item_template|/results|row|")
    }

    @Test("A functional control identity does not prove the current parameter's target value")
    func wrongParameterizedTargetWithSameKey() {
        let call = RecallUseLinking.Call(eventID: "c", request: .act(target: "Invoice-999", verb: .click, value: nil, section: nil),
                                       checkPassed: true, bundleID: Self.app, entry: .state("main"), elementKey: "item_template|/results|row|")
        let link = RecallUseLinking.link(steps: [Self.targetStep()], calls: [call], values: ["record": "Invoice-123"]).first
        #expect(link?.stepPosition == nil, "The UI control may be the same; the required record is different")
        #expect(link?.confirmed == false)
    }

    @Test("A matching control identity cannot bind an unresolved target parameter")
    func unboundParameterizedTargetWithSameKey() {
        let call = RecallUseLinking.Call(eventID: "c", request: .act(target: "Invoice-999", verb: .click, value: nil, section: nil),
                                       checkPassed: true, bundleID: Self.app, entry: .state("main"), elementKey: "item_template|/results|row|")
        let link = RecallUseLinking.link(steps: [Self.targetStep()], calls: [call], values: [:]).first
        #expect(link?.stepPosition == nil)
        #expect(link?.confirmed == false)
    }

    @Test("An integer parameter supported by D2 can confirm its actual integer argument")
    func integerParameterCanConfirm() {
        let step = S.step(0, tool: .scroll, [("direction", S.text("down")), ("lines", .parameter("amount")),
                                          ("target", S.text("Results"))], bundle: Self.app, entry: .state("main"))
        let call = RecallUseLinking.Call(eventID: "c", request: .scroll(direction: .down, lines: 3, target: "Results", section: nil),
                                       checkPassed: true, bundleID: Self.app, entry: .state("main"))
        let link = RecallUseLinking.link(steps: [step], calls: [call], values: ["amount": "3"]).first
        #expect(link?.stepPosition == 0, "The parameter's canonical binding is textual but the recorded argument is integer")
        #expect(link?.confirmed == true)
    }

    @Test("Equal historical text does not make a folder output the producer of an unrelated note title")
    func equalValuesDoNotProveDependency() throws {
        let steps = [
            S.step(0, part: "equal", tool: .typeText, [("target", S.text("Folder name")), ("text", S.text("2026")),
                                                      ("replace", .literal(.boolean(true)))],
                   bundle: S.finder, entry: .state("rename"), exit: .state("rename"), label: "Name the folder 2026"),
            S.step(1, part: "equal", tool: .typeText, [("target", S.text("Note title")), ("text", .parameter("title")),
                                                      ("replace", .literal(.boolean(true)))],
                   bundle: "com.apple.Notes", entry: .state("note"), exit: .state("note"), label: "Set the requested note title")
        ]
        let parts: [RecallSource.Part] = [
            .init(partID: "equal/procedure", kind: .procedure, firstPosition: 0, lastPosition: 1,
                  label: "Name a folder and write an unrelated note title", bundleID: nil, isOffered: true),
            .init(partID: "equal/b1", kind: .subprocedure, firstPosition: 0, lastPosition: 0,
                  label: "Name a folder", bundleID: S.finder, isOffered: true),
            .init(partID: "equal/b2", kind: .subprocedure, firstPosition: 1, lastPosition: 1,
                  label: "Write the requested note title", bundleID: "com.apple.Notes", isOffered: true)
        ] + steps.map { .init(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                             label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        let parameters: [RecallSource.Parameter] = [
            .init(parameterID: "folder", name: "renamed_folder", role: "folder reference", kind: .folder, direction: .output,
                  unit: nil, observedValues: ["2026"], producedBy: "equal/b1"),
            .init(parameterID: "title", name: "note_title", role: "title requested by the person", kind: .text, direction: .input,
                  unit: nil, observedValues: ["2026"])
        ]
        let source = RecallSource(routeID: "equal", procedureLabel: "Name a folder and write an unrelated note title", steps: steps,
                                  parts: parts, parameters: parameters, confirmedUses: 0)
        let outcome = S.select([S.scored(source, steps: [0: 0.1, 1: 0.9])], need: "Set the note title", values: [])
        #expect(outcome.coverage != .complete, "The required title is missing, and no dependency from the folder was declared")
        #expect(outcome.selected?.requirements.contains { $0.kind == .inputProduced } != true)
    }
}
