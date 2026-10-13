//
//  RecallProvenanceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import Testing

/// RecallProvenanceTests prove that an input is fed by an earlier part's output only when the source's attempts state
/// it (the input's binding names that output as its source), never because two values were equal: a true dependency
/// brings its producer, an output the task holds spares it, equal values with no stated relation leave the input
/// missing, and of two producers with equal values the one named is the producer.
@Suite("The Recall relates an input to an earlier output only by its stated origin")
struct RecallProvenanceTests {

    typealias S = RecallSelectionTests
    typealias Scope = RecallScopeSelectionTests

    static let invoice = Scope.invoiceMail
    /// A need that names the email only: what is selected beyond it comes from the stated relation, never from the need.
    static let need = "Email the invoice to luca@example.com"
    static let values = [S.value("recipient", "luca@example.com")]

    static func origin(_ source: TaskValueSource, _ reference: String?, task: String = "task-inv",
                       value: String? = "/Users/me/Downloads/INV-1.pdf") -> RecallSource.Origin {
        RecallSource.Origin(source: source, reference: reference, attemptID: "attempt-inv", taskID: task, value: value)
    }

    /// The invoice version with the attachment's kind and origins replaced.
    static func invoice(kind: TaskValueKind = .file, origins: [RecallSource.Origin]) -> RecallSource {
        let base = Scope.invoiceMail(attachment: nil)
        let parameters = base.parameters.map { parameter -> RecallSource.Parameter in
            guard parameter.parameterID == "attachment" else { return parameter }
            return RecallSource.Parameter(parameterID: "attachment", name: "attachment", role: parameter.role, kind: kind,
                                          direction: .input, unit: nil, observedValues: parameter.observedValues, origins: origins)
        }
        return RecallSource(routeID: base.routeID, procedureLabel: base.procedureLabel, steps: base.steps, parts: base.parts,
                            parameters: parameters, confirmedUses: 0)
    }

    static func emailing(_ source: RecallSource, values: [TaskValue] = values) -> NeedOutcome {
        S.select([S.scored(source, steps: Scope.emailInvoice, parts: ["inv/block-1": 0.9])], need: need, values: values)
    }

    /// The outcome with no producer: the email alone, its attachment still to ask for.
    static func missingAttachment(_ outcome: NeedOutcome) -> Bool {
        guard let selected = outcome.selected else { return false }
        return selected.positions == 3...6 && outcome.coverage == .ambiguous
            && selected.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "attachment" }
            && !selected.requirements.contains { $0.kind == .inputProduced }
    }

    @Test("a downloaded file attached later: the stated origin brings the download in; without it the attachment is missing")
    func trueDependency() throws {
        let stated = try #require(Self.emailing(Scope.invoiceMail()).selected)
        #expect(stated.positions == 0...6)
        #expect(stated.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "attachment" && $0.stepPosition == 0 })
        let attachment = try #require(Scope.invoiceMail().parameters.first { $0.parameterID == "attachment" })
        let feed = try #require(Scope.invoiceMail().feed(of: attachment))
        #expect(feed.output.parameterID == "file" && feed.isSame && feed.origins.map(\.reference) == ["task-inv/invoice_file"],
                "the relation keeps the statement it rests on")
        #expect(Self.missingAttachment(Self.emailing(Scope.invoiceMail(attachment: nil))),
                "the same values, no stated origin: no relation, the download is not planned")
        let named = try #require(Self.emailing(Self.invoice(origins: [Self.origin(.previousOutput, "invoice_file")])).selected)
        #expect(named.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "attachment" },
                "the output named as the interpretation names it")
        #expect(Self.missingAttachment(Self.emailing(Self.invoice(origins: [Self.origin(.previousOutput, "[withheld]")]))),
                "a reference the archive withheld names nothing")
    }

    @Test("an output the task already holds spares its producer, also for an input derived from it, which stays to derive")
    func readyOutputSparesProducer() throws {
        let ready = S.value("invoice_file", "/Users/me/Downloads/INV-2.pdf", role: "the downloaded invoice", kind: .file)
        let same = try #require(Self.emailing(Scope.invoiceMail(), values: [S.value("recipient", "luca@example.com"), ready]).selected)
        #expect(same.positions == 3...6)
        #expect(same.requirements.contains { $0.kind == .parameterBound && $0.parameterID == "attachment" && $0.bindingMatch == .produced })
        let derived = Self.invoice(origins: [Self.origin(.derived, "task-inv/invoice_file")])
        let outcome = Self.emailing(derived, values: [S.value("recipient", "luca@example.com"), ready])
        #expect(Self.missingAttachment(outcome), "a value derived from the output is not the output: the agent derives it")
        let produced = try #require(Self.emailing(derived).selected)
        #expect(produced.positions == 0...6 && produced.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "attachment" },
                "the output not held: its producer is planned, and the input derived from what it produces")
    }

    @Test("an origin another statement contradicts, or that names no output of this attempt's task, relates nothing")
    func contradictedOrigins() {
        let stated = Self.origin(.previousOutput, "task-inv/invoice_file")
        #expect(Self.missingAttachment(Self.emailing(Self.invoice(origins: [stated, Self.origin(.request, nil)]))),
                "another attempt took it from the request")
        #expect(Self.missingAttachment(Self.emailing(Self.invoice(origins: [Self.origin(.previousOutput, "task-other/invoice_file")]))),
                "an earlier task's output is a value the task gives, not this version's producer")
        #expect(Self.missingAttachment(Self.emailing(Self.invoice(origins: [Self.origin(.previousOutput, "task-inv/invoice")]))),
                "an input is no output")
        #expect(Self.missingAttachment(Self.emailing(Self.invoice(kind: .text, origins: [stated]))), "an output of another kind is not itself")
        #expect(Self.missingAttachment(Self.emailing(Self.invoice(origins: [Self.origin(.previousOutput, "task-inv/invoice_file",
                                                                                         value: "/Users/me/Downloads/OTHER.pdf")]))),
                "a value the output never had")
        let unknown = Self.invoice(origins: [stated, Self.origin(.unknown, nil)])
        #expect(Self.emailing(unknown).selected?.requirements.contains { $0.kind == .inputProduced } == true,
                "an attempt that cannot name the source states nothing against it")
    }

    @Test("equal values of independent parameters: the request's title is never filled by a folder output of the same text")
    func equalIndependentValues() throws {
        let steps = [
            S.step(0, part: "equal", tool: .typeText, [("target", S.text("Folder name")), ("text", S.text("2026")),
                                                      ("replace", .literal(.boolean(true)))],
                   bundle: S.finder, entry: .state("rename"), exit: .state("rename"), label: "Name the folder 2026"),
            S.step(1, part: "equal", tool: .typeText, [("target", S.text("Note title")), ("text", .parameter("title")),
                                                      ("replace", .literal(.boolean(true)))],
                   bundle: "com.apple.Notes", entry: .state("note"), exit: .state("note"), label: "Set the requested note title"),
        ]
        let parts: [RecallSource.Part] = [
            .init(partID: "equal/procedure", kind: .procedure, firstPosition: 0, lastPosition: 1, label: "Name a folder and title a note",
                  bundleID: nil, isOffered: true),
            .init(partID: "equal/b1", kind: .subprocedure, firstPosition: 0, lastPosition: 0, label: "Name a folder", bundleID: S.finder,
                  isOffered: true),
            .init(partID: "equal/b2", kind: .subprocedure, firstPosition: 1, lastPosition: 1, label: "Write the requested note title",
                  bundleID: "com.apple.Notes", isOffered: true),
        ] + steps.map { .init(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position, label: $0.label,
                              bundleID: $0.bundleID, isOffered: true) }
        let fromRequest = RecallSource.Origin(source: .request, reference: nil, attemptID: "attempt-equal", taskID: "task-equal", value: "2026")
        let source = RecallSource(routeID: "equal", procedureLabel: "Name a folder and title a note", steps: steps, parts: parts, parameters: [
            .init(parameterID: "folder", name: "renamed_folder", role: "folder reference", kind: .folder, direction: .output, unit: nil,
                  observedValues: ["2026"], producedBy: "equal/b1"),
            .init(parameterID: "title", name: "note_title", role: "title requested by the person", kind: .text, direction: .input, unit: nil,
                  observedValues: ["2026"], origins: [fromRequest]),
        ], confirmedUses: 0)
        let outcome = S.select([S.scored(source, steps: [0: 0.1, 1: 0.9])], need: "Set the note title", values: [])
        let selected = try #require(outcome.selected)
        #expect(outcome.coverage == .ambiguous && selected.positions == 1...1)
        #expect(selected.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "title" })
        #expect(!selected.requirements.contains { $0.kind == .inputProduced })
    }

    /// A report exported from Pages and a report downloaded in Safari, both named report.pdf, then an email with an
    /// attachment: which file the attachment was is what the attempt states, not the nearest equal value.
    static func twoReports(attachment reference: String?) -> RecallSource {
        let pages = "com.apple.iWork.Pages", safari = Scope.safari, mail = Scope.mail
        let steps = [
            S.step(0, part: "rep", tool: .menu, [("path", S.text("File > Export To > PDF…"))], bundle: pages, entry: .state("document"),
                   label: "Export the report as PDF"),
            S.step(1, part: "rep", tool: .act, [("target", S.text("Download")), ("verb", S.text("click"))], bundle: safari,
                   entry: .state("portal"), label: "Download the shared report"),
            S.step(2, part: "rep", tool: .act, [("target", S.text("New Message")), ("verb", S.text("click"))], bundle: mail,
                   entry: .state("viewer"), exit: .state("compose"), label: "Start a new email"),
            S.step(3, part: "rep", tool: .typeText, [("target", S.text("To")), ("text", .parameter("recipient"))], bundle: mail,
                   entry: .state("compose"), label: "Type <recipient> in To"),
            S.step(4, part: "rep", tool: .typeText, [("target", S.text("Attachment")), ("text", .parameter("attachment"))], bundle: mail,
                   entry: .state("compose"), label: "Attach <attachment>"),
            S.step(5, part: "rep", tool: .act, [("target", S.text("Send")), ("verb", S.text("click"))], bundle: mail,
                   entry: .state("compose"), exit: .state("viewer"), label: "Send the email"),
        ]
        let parts: [RecallSource.Part] = [
            .init(partID: "rep/procedure", kind: .procedure, firstPosition: 0, lastPosition: 5, label: "Export and download reports, email one",
                  bundleID: nil, isOffered: true),
            .init(partID: "rep/block-0", kind: .subprocedure, firstPosition: 0, lastPosition: 0, label: "Export the report from Pages",
                  bundleID: pages, isOffered: true),
            .init(partID: "rep/block-1", kind: .subprocedure, firstPosition: 1, lastPosition: 1, label: "Download the shared report",
                  bundleID: safari, isOffered: true),
            .init(partID: "rep/block-2", kind: .subprocedure, firstPosition: 2, lastPosition: 5, label: "Email <attachment> to <recipient>",
                  bundleID: mail, isOffered: true),
        ] + steps.map { .init(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position, label: $0.label,
                              bundleID: $0.bundleID, isOffered: true) }
        let origins = reference.map { [RecallSource.Origin(source: .previousOutput, reference: $0, attemptID: "attempt-rep", taskID: "task-rep",
                                                           value: "report.pdf")] } ?? []
        return RecallSource(routeID: "rep", procedureLabel: "Export and download reports, email one", steps: steps, parts: parts, parameters: [
            .init(parameterID: "exported", name: "exported_report", role: "the report exported from Pages", kind: .file, direction: .output,
                  unit: nil, observedValues: ["report.pdf"], producedBy: "rep/block-0"),
            .init(parameterID: "downloaded", name: "downloaded_report", role: "the report downloaded from the portal", kind: .file,
                  direction: .output, unit: nil, observedValues: ["report.pdf"], producedBy: "rep/block-1"),
            S.parameter("recipient", "recipient", role: "email address of the recipient", observed: ["anna@example.com"]),
            .init(parameterID: "attachment", name: "attachment", role: "the document attached", kind: .file, direction: .input, unit: nil,
                  observedValues: ["report.pdf"], origins: origins),
        ], confirmedUses: 0)
    }

    /// Review F10 changed the scope expected of the first case, not its causality: the stated producer is still the Pages
    /// export, but the independent download between it and the email is no part of the need or of the dependency, so the
    /// selection is the email alone, its attachment missing and the export named as the part that produced it. It was
    /// 0...5, the download included.
    @Test("two producers of equal file names: the stated one is the producer, the nearest equal value is not")
    func twoProducersOfEqualValues() throws {
        func emailing(_ source: RecallSource) -> NeedOutcome {
            S.select([S.scored(source, steps: [2: 0.6, 3: 0.6, 4: 0.6, 5: 0.6], parts: ["rep/block-2": 0.9])],
                     need: "Email the report to luca@example.com", values: [S.value("recipient", "luca@example.com")])
        }
        let exportedSource = Self.twoReports(attachment: "task-rep/exported_report")
        let exported = try #require(emailing(exportedSource).selected)
        #expect(exported.positions == 2...5, "the download between the producer and the email is not delivered")
        #expect(exported.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "attachment" })
        let attachment = try #require(exportedSource.parameters.first { $0.parameterID == "attachment" })
        #expect(exportedSource.feed(of: attachment)?.output.producedBy == "rep/block-0",
                "the Pages export, not the nearer download of a file with the same name")
        let downloaded = try #require(emailing(Self.twoReports(attachment: "task-rep/downloaded_report")).selected)
        #expect(downloaded.positions == 1...5)
        #expect(downloaded.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "attachment" && $0.stepPosition == 1 })
        let unstated = emailing(Self.twoReports(attachment: nil))
        #expect(unstated.selected?.positions == 2...5 && unstated.coverage == .ambiguous)
        #expect(unstated.selected?.requirements.contains { $0.kind == .inputProduced } == false)
    }
}
