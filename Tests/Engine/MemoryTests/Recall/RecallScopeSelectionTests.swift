//
//  RecallScopeSelectionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
@testable import Memory
import Testing

/// RecallScopeSelectionTests prove what a selection may leave out and must exclude, on versions built by hand: a
/// certain conflict apart from an unknown compatibility and a missing input (R47), the task's constraints, the
/// episodes at the edges the need does not ask for, the state an observation shows, and the producers of the inputs
/// a selection reads (R45, R48). The relevances are given, not computed.
@Suite("The Recall's exclusions, delimitation and producers on versions built by hand")
struct RecallScopeSelectionTests {

    typealias S = RecallSelectionTests

    static let notes = "com.apple.Notes"
    static let mail  = "com.apple.mail"
    static let safari = "com.apple.Safari"

    // MARK: Certain conflict, unknown compatibility, missing input (F03)

    /// The photo export with its format fixed in the source: `select Format = JPEG` as a literal.
    static func fixedJPEG() -> RecallSource {
        let photo = S.photo(route: "fixed")
        let steps = photo.steps.map { step -> RecallSource.Step in
            guard step.position == 5 else { return step }
            return S.step(5, part: "fixed", tool: .select, [("control", S.text("Format")), ("item", S.text("JPEG"))], bundle: S.preview,
                          entry: .state("dialog"), label: "Choose JPEG")
        }
        return RecallSource(routeID: "fixed", procedureLabel: photo.procedureLabel, steps: steps, parts: photo.parts,
                            parameters: photo.parameters.filter { $0.parameterID != "format" }, confirmedUses: 0)
    }

    static let exportSteps: [Int: Double] = [3: 0.8, 4: 0.7, 5: 0.75, 6: 0.6]

    @Test("a fixed JPEG export is excluded for a task that requires PNG; the version's other episodes stay selectable")
    func fixedConflictKeepsCompatiblePortions() throws {
        let export = S.select([S.scored(Self.fixedJPEG(), steps: Self.exportSteps)])
        #expect(export.selected == nil && export.coverage == .absent && export.reason == .excluded)
        let excluded = try #require(export.excluded.first)
        #expect(excluded.positions == 3...6, "the whole dialog episode produces the JPEG file")
        #expect(excluded.requirements == [RecallRequirement(kind: .certainConflict, stepPosition: 5, bundleID: S.preview,
                                                            taskValueName: "output_format")])
        let whole = S.select([S.scored(Self.fixedJPEG(), steps: Self.exportSteps, parts: ["fixed/procedure": 0.95, "fixed/block-1": 0.95])])
        #expect(whole.selected == nil && whole.reason == .excluded, "what remains of a whole without its export is not relevant to an export")
        let rotate = S.select([S.scored(Self.fixedJPEG(), steps: [2: 0.9])], need: "Rotate the open image to the right")
        #expect(rotate.selected?.positions == 2...2 && rotate.coverage == .complete, "the rotation does not choose a format")
        #expect(rotate.excluded.isEmpty, "the excluded episode is not relevant to this need")
    }

    @Test("a parametric format observed as JPEG is an unknown compatibility for PNG: delivered with the condition, not excluded")
    func parametricIsUnknownCompatibility() throws {
        let outcome = S.select([S.scored(S.photo(), steps: Self.exportSteps)])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 3...6 && outcome.coverage == .complete && outcome.excluded.isEmpty)
        #expect(selected.requirements.contains { $0.kind == .compatibilityUnknown && $0.stepPosition == 5 && $0.parameterID == "format" })
        #expect(!selected.requirements.contains { $0.isExclusion })
    }

    @Test("a format the task still lacks is an input to resolve, for a parametric method and for a fixed one alike")
    func missingFormatIsUnresolved() throws {
        let lacking = [S.value("output_name", "foto_mail"), S.value("output_extension", "png"),
                       try TaskValue(name: "output_format", role: "format of the exported file", kind: .missing, content: .missing,
                                     source: .request)]
        let parametric = S.select([S.scored(S.photo(), steps: Self.exportSteps)], values: lacking)
        #expect(parametric.coverage == .ambiguous && parametric.reason == .unresolvedInput)
        #expect(parametric.selected?.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "format" } == true)
        let fixed = S.select([S.scored(Self.fixedJPEG(), steps: Self.exportSteps)], values: lacking)
        #expect(fixed.coverage == .ambiguous && fixed.reason == .unresolvedInput && fixed.excluded.isEmpty, "unknown, not a conflict")
        #expect(fixed.selected?.requirements.contains { $0.kind == .unboundTaskInput && $0.taskValueName == "output_format" } == true)
    }

    @Test("an incompatible value the constraints also forbid is excluded with both reasons")
    func conflictAlsoForbidden() throws {
        let outcome = S.select([S.scored(Self.fixedJPEG(), steps: Self.exportSteps)], constraints: ["Never save it as JPEG"])
        #expect(outcome.selected == nil && outcome.reason == .excluded)
        let kinds = Set(try #require(outcome.excluded.first).requirements.map(\.kind))
        #expect(kinds == [.certainConflict, .constraintExcluded])
        #expect(outcome.excluded.first?.requirements.first { $0.kind == .constraintExcluded }?.constraintPosition == 0)
    }

    // MARK: Constraints

    @Test("a prohibition is read clause by clause: an application named with a verb of opening, or all of a clause's words")
    func constraintClauses() throws {
        let constraint = try #require(RecallConstraint.parse(["Do not share the note and do not open Mail"]).first)
        #expect(constraint.forbidden.map(\.words) == [["share", "note"], ["open", "mail"]] && !constraint.hasUnchecked)
        let share = S.step(2, tool: .contextMenu, [("target", S.text("Share")), ("item", S.text("Mail"))], bundle: Self.notes,
                           entry: .state("notes"), label: "Share the note through Mail")
        let create = S.step(0, tool: .act, [("target", S.text("New Note"))], bundle: Self.notes, entry: .state("notes"),
                            label: "Create a new note")
        let send = S.step(4, tool: .act, [("target", S.text("Send"))], bundle: Self.mail, entry: .state("compose"), label: "Send the email")
        #expect(constraint.forbids(share) && constraint.forbids(send) && !constraint.forbids(create))
        let italian = try #require(RecallConstraint.parse(["Non condividere la nota, senza aprire Mail"]).first)
        #expect(italian.forbids(send) && !italian.forbids(create))
        let carried = try #require(RecallConstraint.parse(["Don't share the note or open Mail"]).first)
        #expect(carried.forbidden.count == 2)
        let positive = try #require(RecallConstraint.parse(["Keep the note private"]).first)
        #expect(positive.forbidden.isEmpty && positive.hasUnchecked)
        let mixed = try #require(RecallConstraint.parse(["Do not open Mail; finish before noon"]).first)
        #expect(mixed.forbidden.count == 1 && mixed.hasUnchecked)
    }

    /// A note created, titled and shared through Mail, then sent from Mail: D2's notes-share-mail as the Recall reads it.
    static func notesShare() -> RecallSource {
        let steps = [
            S.step(0, part: "n", tool: .act, [("target", S.text("New Note"))], bundle: Self.notes, entry: .state("notes"),
                   label: "Create a new note"),
            S.step(1, part: "n", tool: .typeText, [("target", S.text("Note title")), ("text", .parameter("title"))], bundle: Self.notes,
                   entry: .state("notes"), label: "Type <note_title> as the note's title"),
            S.step(2, part: "n", tool: .contextMenu, [("target", S.text("Share")), ("item", S.text("Mail"))], bundle: Self.notes,
                   entry: .state("notes"), label: "Share the note through Mail"),
            S.step(3, part: "n", tool: .typeText, [("target", S.text("To")), ("text", .parameter("recipient"))], bundle: Self.mail,
                   entry: .state("compose"), label: "Type <recipient> in To"),
            S.step(4, part: "n", tool: .act, [("target", S.text("Send"))], bundle: Self.mail, entry: .state("compose"), exit: .state("viewer"),
                   label: "Send the email"),
        ]
        let parts = [
            RecallSource.Part(partID: "n/procedure", kind: .procedure, firstPosition: 0, lastPosition: 4,
                              label: "Create a note titled <note_title> and email it to <recipient>", bundleID: nil, isOffered: true),
            RecallSource.Part(partID: "n/block-0", kind: .subprocedure, firstPosition: 0, lastPosition: 2,
                              label: "Create a note titled <note_title> and share it by Mail", bundleID: Self.notes, isOffered: true),
            RecallSource.Part(partID: "n/block-1", kind: .subprocedure, firstPosition: 3, lastPosition: 4,
                              label: "Send the shared note to <recipient>", bundleID: Self.mail, isOffered: true),
        ] + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                          label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: "n", procedureLabel: "Create a note titled <note_title> and email it to <recipient>", steps: steps,
                            parts: parts, parameters: [
                                S.parameter("title", "note_title", role: "title of the note", observed: ["Riunione"]),
                                S.parameter("recipient", "recipient", role: "email address of the recipient", observed: ["paolo@example.com"]),
                            ], confirmedUses: 0)
    }

    static let createNote = "Create a new note titled Idee in Notes"
    static let idee = [S.value("note_title", "Idee")]

    @Test("a need that only creates the note gets creation and title: the sharing at the end of the subprocedure is no part of it")
    func trailingEpisodeTrimmed() throws {
        let scored = S.scored(Self.notesShare(), steps: [0: 0.55, 1: 0.6, 2: 0.3], parts: ["n/block-0": 0.9])
        let outcome = S.select([scored], need: Self.createNote, values: Self.idee)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 0...1 && outcome.coverage == .complete)
        #expect(selected.wholePartID == nil, "a tract of the subprocedure, not the subprocedure")
    }

    @Test("the constraint excludes the sharing even when its relevance is high; the relevant excluded episode is named")
    func constraintExcludesSharing() throws {
        let scored = S.scored(Self.notesShare(), steps: [0: 0.7, 1: 0.7, 2: 0.7], parts: ["n/block-0": 0.75])
        let free = S.select([scored], need: Self.createNote, values: Self.idee)
        #expect(free.selected?.positions == 0...1, "the need names no word of the sharing: relevance alone does not join it")
        let outcome = S.select([scored], need: Self.createNote, values: Self.idee, constraints: ["Do not share the note and do not open Mail"])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 0...1 && outcome.coverage == .complete)
        #expect(!selected.requirements.contains { $0.kind == .constraintUnchecked }, "every clause of it was checked")
        #expect(outcome.excluded.map(\.positions) == [2...2])
        #expect(outcome.excluded.first?.requirements.map(\.kind) == [.constraintExcluded])
    }

    @Test("a subprocedure clearly relevant as a whole keeps, under the constraint, its run without the forbidden sharing")
    func constraintCutsWhole() throws {
        let scored = S.scored(Self.notesShare(), steps: [0: 0.55, 1: 0.45, 2: 0.3], parts: ["n/block-0": 0.9, "n/procedure": 0.6])
        let outcome = S.select([scored], need: Self.createNote, values: Self.idee, constraints: ["Do not share the note and do not open Mail"])
        #expect(outcome.selected?.positions == 0...1 && outcome.coverage == .complete)
    }

    @Test("a constraint the selector cannot check stays a condition of the selection, never satisfied")
    func uncheckedConstraint() throws {
        let scored = S.scored(Self.notesShare(), steps: [0: 0.7, 1: 0.7], parts: [:])
        let outcome = S.select([scored], need: Self.createNote, values: Self.idee, constraints: ["Keep it short"])
        #expect(outcome.coverage == .complete)
        #expect(outcome.selected?.requirements.contains { $0.kind == .constraintUnchecked && $0.constraintPosition == 0 } == true)
    }

    /// Review F11 changed the coverage expected of the second need, not its selection: "Write a note …" states, with a verb
    /// the method does not know, the creation the source did first, which the selection leaves out. It was complete; it is
    /// partial, the verb named, which is the false complete the second round reported as residual.
    @Test("a first episode the need names is selected; one it does not name is stated as done before, never repeated unasked")
    func leadingPreparationKept() throws {
        let scored = S.scored(Self.notesShare(), steps: [0: 0.3, 1: 0.5, 2: 0.3, 3: 0.5, 4: 0.4], parts: ["n/procedure": 0.95])
        let values = [S.value("note_title", "Budget"), S.value("recipient", "sara@example.com")]
        let named = try #require(S.select([scored], need: "Create a new note titled Budget and email it to sara@example.com", values: values).selected)
        #expect(named.positions == 0...4 && named.wholePartID == "n/procedure", "the creation is asked")
        let outcome = S.select([scored], need: "Write a note titled Budget and email it to sara@example.com", values: values)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 1...4, "no word of the need names the creation")
        #expect(outcome.coverage == .partial && outcome.reason == .gaps && outcome.unaccounted == ["write"],
                "the work \"write\" states is not one this selection is known to do")
        #expect(selected.requirements.contains { $0.kind == .preparedBefore && $0.stepPosition == 0 },
                "the creation the source did first is stated, for the agent to check, not planned again")
    }

    /// Review F11 changed the coverage expected, not the selection: the clause "edited as …" states work (done, in words)
    /// with a verb the method does not know, which the rule cannot read. It was complete; it is partial, the verb named.
    @Test("a first episode the need says nothing of is left out of a whole part when the task declares a ready input, and named as done before")
    func leadingEditLeftOut() throws {
        let scored = S.scored(S.photo(), steps: [2: 0.1, 3: 0.6, 4: 0.55, 5: 0.55, 6: 0.5], parts: ["photo/block-1": 0.9])
        let document = try TaskValue(name: "document", kind: .file, content: .text("foto_demo.png"), source: .previousOutput,
                                     sourceRef: "task-1/exported")
        let need = "Export the document already open and edited as foto_mail.png in PNG"
        let outcome = S.select([scored], need: need, values: S.exportValues + [document])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 3...6 && outcome.coverage == .partial && outcome.unaccounted == ["edited"], "\(outcome.unaccounted)")
        #expect(selected.requirements.contains { $0.kind == .preparedBefore && $0.stepPosition == 2 })
        let undeclared = S.select([scored], need: need)
        #expect(undeclared.selected?.positions == 3...6, "a ready input is no proof of which work is done: the same selection without it")
        #expect(undeclared.selected?.requirements.contains { $0.kind == .preparedBefore && $0.stepPosition == 2 } == true)
    }

    // MARK: The observed state

    @Test("a dialog the latest observation shows open: a need about one of its controls gets that control alone")
    func observedDialog() throws {
        let observed: Set<ObservedState> = [ObservedState(bundleID: S.preview, sceneID: "dialog")]
        let outcome = S.select([S.scored(S.photo(), steps: [3: 0.6, 5: 0.9])], need: "Choose PNG as the format", observed: observed)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 5...5 && outcome.coverage == .complete)
        #expect(selected.requirements.first == RecallRequirement(kind: .observedState, stepPosition: 5, sceneID: "dialog", bundleID: S.preview))
        #expect(selected.requirements.contains { $0.kind == .compatibilityUnknown && $0.stepPosition == 5 })
        let closed = S.select([S.scored(S.photo(), steps: [3: 0.6, 5: 0.9])], need: "Choose PNG as the format")
        #expect(closed.selected?.positions == 3...6, "without the observation the dialog is opened and confirmed")
        let elsewhere = S.select([S.scored(S.photo(), steps: [3: 0.6, 5: 0.9])], need: "Choose PNG as the format",
                                 observed: [ObservedState(bundleID: S.finder, sceneID: "finder")])
        #expect(elsewhere.selected?.positions == 3...6, "a state of another application cuts nothing")
    }

    @Test("an export whose dialog is already open continues from it: the menu that opened it is not repeated")
    func observedDialogWholeExport() throws {
        let observed: Set<ObservedState> = [ObservedState(bundleID: S.preview, sceneID: "dialog")]
        let scored = S.scored(S.photo(), steps: [2: 0.1, 3: 0.6, 4: 0.6, 5: 0.6, 6: 0.6], parts: ["photo/block-1": 0.9])
        let outcome = S.select([scored], need: "Export it as foto_mail.png in PNG", observed: observed)
        let selected = try #require(outcome.selected)
        #expect(selected.positions.lowerBound == 4 && selected.positions.upperBound == 6)
        #expect(selected.requirements.first?.kind == .observedState)
        #expect(!selected.requirements.contains { $0.kind == .preparedBefore && $0.stepPosition == 3 }, "the menu is done, not unknown")
    }

    // MARK: Producers

    /// A download in Safari whose file is then attached to an email in Mail: the output of the first part is the
    /// input of the second, as the source's attempt states it (the attachment's binding names the downloaded file as
    /// its source: `previous_output`, `<task id>/invoice_file`).
    static func invoiceMail(attachment origin: RecallSource.Origin? = invoiceOrigin) -> RecallSource {
        let path = "/Users/me/Downloads/INV-1.pdf"
        let steps = [
            S.step(0, part: "inv", tool: .act, [("target", S.text("Invoices"))], bundle: Self.safari, entry: .state("portal"),
                   label: "Open the invoices page"),
            S.step(1, part: "inv", tool: .act, [("target", .parameter("invoice"))], bundle: Self.safari, entry: .state("portal"),
                   label: "Select invoice <invoice>"),
            S.step(2, part: "inv", tool: .act, [("target", S.text("Download PDF"))], bundle: Self.safari, entry: .state("portal"),
                   label: "Download the selected invoice as PDF"),
            S.step(3, part: "inv", tool: .act, [("target", S.text("New Message"))], bundle: Self.mail, entry: .state("viewer"),
                   exit: .state("compose"), label: "Start a new email"),
            S.step(4, part: "inv", tool: .typeText, [("target", S.text("To")), ("text", .parameter("recipient"))], bundle: Self.mail,
                   entry: .state("compose"), label: "Type <recipient> in To"),
            S.step(5, part: "inv", tool: .typeText, [("target", S.text("Attachment")), ("text", .parameter("attachment"))],
                   bundle: Self.mail, entry: .state("compose"), label: "Attach <attachment>"),
            S.step(6, part: "inv", tool: .act, [("target", S.text("Send"))], bundle: Self.mail, entry: .state("compose"),
                   exit: .state("viewer"), label: "Send the email"),
        ]
        let parts = [
            RecallSource.Part(partID: "inv/procedure", kind: .procedure, firstPosition: 0, lastPosition: 6,
                              label: "Download invoice <invoice> and email it to <recipient>", bundleID: nil, isOffered: true),
            RecallSource.Part(partID: "inv/block-0", kind: .subprocedure, firstPosition: 0, lastPosition: 2,
                              label: "Download invoice <invoice> from the portal", bundleID: Self.safari, isOffered: true),
            RecallSource.Part(partID: "inv/block-1", kind: .subprocedure, firstPosition: 3, lastPosition: 6,
                              label: "Email <attachment> to <recipient>", bundleID: Self.mail, isOffered: true),
        ] + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                          label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: "inv", procedureLabel: "Download invoice <invoice> and email it to <recipient>", steps: steps,
                            parts: parts, parameters: [
                                S.parameter("invoice", "invoice", role: "number of the invoice", observed: ["INV-1"]),
                                RecallSource.Parameter(parameterID: "file", name: "invoice_file", role: "the downloaded invoice", kind: .file,
                                                       direction: .output, unit: nil, observedValues: [path], producedBy: "inv/block-0"),
                                S.parameter("recipient", "recipient", role: "email address of the recipient", observed: ["anna@example.com"]),
                                RecallSource.Parameter(parameterID: "attachment", name: "attachment", role: "path of the document attached",
                                                       kind: .file, direction: .input, unit: nil, observedValues: [path],
                                                       origins: origin.map { [$0] } ?? []),
                            ], confirmedUses: 0)
    }

    /// The attachment's origin in the source's attempt: the file the download produced, by the task's output name.
    static let invoiceOrigin = RecallSource.Origin(source: .previousOutput, reference: "task-inv/invoice_file", attemptID: "attempt-inv",
                                                   taskID: "task-inv", value: "/Users/me/Downloads/INV-1.pdf")

    static let emailInvoice: [Int: Double] = [3: 0.6, 4: 0.6, 5: 0.6, 6: 0.6]

    @Test("an input the task lacks that an earlier part produced in the source brings that part into the selection")
    func inputProducedIncluded() throws {
        let scored = S.scored(Self.invoiceMail(), steps: Self.emailInvoice, parts: ["inv/block-1": 0.9])
        let outcome = S.select([scored], need: "Email the invoice INV-2 to luca@example.com",
                               values: [S.value("recipient", "luca@example.com"), S.value("invoice", "INV-2")])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 0...6 && outcome.coverage == .complete)
        #expect(selected.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "attachment" && $0.stepPosition == 0 })
        #expect(!selected.requirements.contains { $0.kind == .parameterMissing })
    }

    @Test("the task already holding what the earlier part produced: that part is not repeated and the input takes the value")
    func readyOutputNotRepeated() throws {
        let ready = S.value("invoice_file", "/Users/me/Downloads/INV-2.pdf", role: "the downloaded invoice", kind: .file)
        let tract = S.select([S.scored(Self.invoiceMail(), steps: Self.emailInvoice, parts: ["inv/block-1": 0.9])],
                             need: "Email the downloaded invoice to luca@example.com", values: [S.value("recipient", "luca@example.com"), ready])
        let selected = try #require(tract.selected)
        #expect(selected.positions == 3...6 && tract.coverage == .complete)
        #expect(selected.requirements.contains { $0.kind == .parameterBound && $0.parameterID == "attachment" && $0.bindingMatch == .produced })
        let whole = S.select([S.scored(Self.invoiceMail(), steps: Self.emailInvoice, parts: ["inv/procedure": 0.95])],
                             need: "Download the invoice and email it to luca@example.com",
                             values: [S.value("recipient", "luca@example.com"), ready])
        let trimmed = try #require(whole.selected)
        #expect(trimmed.positions == 3...6, "the download is not planned again")
        #expect(trimmed.requirements.contains { $0.kind == .outputReady && $0.parameterID == "file" && $0.taskValueName == "invoice_file" })
    }

    @Test("an input no value and no declared producer accounts for is missing: the selection is ambiguous until it is resolved")
    func trulyMissingInput() throws {
        let scored = S.scored(Self.notesShare(), steps: [3: 0.8, 4: 0.7])
        let outcome = S.select([scored], need: "Type the recipient and send the email with the shared note", values: [], app: Self.mail)
        #expect(outcome.selected?.positions == 3...4)
        #expect(outcome.coverage == .ambiguous && outcome.reason == .unresolvedInput)
        #expect(outcome.selected?.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "recipient" } == true)
        #expect(outcome.selected?.requirements.contains { $0.kind == .inputProduced } == false)
        // A need that names the sending only: the step before it, which types the recipient, is stated as done before.
        let sending = S.select([scored], need: "Email the shared note", values: [], app: Self.mail)
        #expect(sending.selected?.positions == 4...4)
        #expect(sending.selected?.requirements.contains { $0.kind == .preparedBefore && $0.stepPosition == 3 } == true)
        #expect(sending.selected?.requirements.contains { $0.kind == .inputProduced } == false)
    }
}
