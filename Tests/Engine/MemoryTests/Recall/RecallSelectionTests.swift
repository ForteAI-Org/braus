//
//  RecallSelectionTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation
@testable import Memory
import Testing

/// RecallSelectionTests prove the D3 selection rules on versions built by hand: the episodes a version is cut into,
/// the interval chosen for a need, its requirements and coverage, the structural ambiguity between variants of one
/// method, the binding of the task's values and their masking in the searched text, and the linking of calls to the
/// steps they carried out. The relevances are given, not computed: what is proved is the decision, not a model.
@Suite("The Recall's selection, binding and use linking on versions built by hand")
struct RecallSelectionTests {

    static let finder  = "com.apple.finder"
    static let preview = "com.apple.Preview"

    static func text(_ value: String) -> OperationValue { .literal(.text(value)) }

    static func step(_ position: Int, part: String = "p", tool: AgentTool, _ arguments: [(String, OperationValue)], bundle: String,
                     entry: RecallSource.Entry, exit: RecallSource.Entry = .unknown, label: String? = nil,
                     offered: Bool = true, elementKey: String? = nil) -> RecallSource.Step {
        var positions: [String: Int] = [:]
        let placed = arguments.map { name, value -> OperationArgument in
            defer { positions[name, default: 0] += 1 }
            return OperationArgument(name: name, position: positions[name] ?? 0, value: value)
        }
        return RecallSource.Step(position: position, partID: "\(part)/step-\(position)", label: label, bundleID: bundle, tool: tool,
                                 arguments: placed, entry: entry, exit: exit, isOffered: offered, elementKey: elementKey)
    }

    static func parameter(_ id: String, _ name: String, role: String, kind: TaskValueKind = .text,
                          observed: [String] = []) -> RecallSource.Parameter {
        RecallSource.Parameter(parameterID: id, name: name, role: role, kind: kind, direction: .input, unit: nil, observedValues: observed)
    }

    /// The photo export of D2's S01 as the Recall reads it: two Finder steps, five in Preview (rotate, then the Export
    /// dialog from its menu to its Save), one in Finder; the states of Finder, of Preview's window and of the dialog.
    static func photo(offered: Set<Int> = Set(0...7), knownEntries: Bool = true, route: String = "photo") -> RecallSource {
        let finder: RecallSource.Entry = knownEntries ? .state("finder") : .unknown
        let editing: RecallSource.Entry = .state("editing")
        let dialog: RecallSource.Entry = knownEntries ? .state("dialog") : .unknown
        let steps = [
            step(0, part: route, tool: .typeText, [("target", text("Search")), ("text", .parameter("criterion"))], bundle: Self.finder,
                 entry: finder, label: "Search <criterion> in Finder", offered: offered.contains(0)),
            step(1, part: route, tool: .act, [("target", text("foto_demo.png")), ("verb", text("click"))], bundle: Self.finder,
                 entry: finder, label: "Select the file found", offered: offered.contains(1)),
            step(2, part: route, tool: .act, [("target", text("Rotate Right")), ("verb", text("click"))], bundle: Self.preview,
                 entry: editing, exit: editing, label: "Rotate the image right", offered: offered.contains(2)),
            step(3, part: route, tool: .menu, [("path", text("File > Export…"))], bundle: Self.preview, entry: editing, exit: dialog,
                 label: "Open the Export dialog", offered: offered.contains(3)),
            step(4, part: route, tool: .typeText, [("target", text("foto_demo.png")),
                                                   ("text", .template([.parameter("name"), .literal("."), .parameter("ext")]))],
                 bundle: Self.preview, entry: dialog, label: "Set <name>.<extension> in the Name field", offered: offered.contains(4)),
            step(5, part: route, tool: .select, [("control", text("Format")), ("item", .parameter("format"))], bundle: Self.preview,
                 entry: dialog, label: "Choose <format>", offered: offered.contains(5)),
            step(6, part: route, tool: .press, [("button", text("Save"))], bundle: Self.preview, entry: dialog, exit: editing,
                 label: "Confirm the export", offered: offered.contains(6)),
            step(7, part: route, tool: .act, [("target", text("Show Preview")), ("verb", text("set_toggle")), ("value", text("on"))],
                 bundle: Self.finder, entry: finder, label: "Show the preview in Finder", offered: offered.contains(7)),
        ]
        var parts = [
            RecallSource.Part(partID: "\(route)/procedure", kind: .procedure, firstPosition: 0, lastPosition: 7,
                              label: "Find <file>, rotate it and export it", bundleID: nil, isOffered: true),
            RecallSource.Part(partID: "\(route)/block-0", kind: .subprocedure, firstPosition: 0, lastPosition: 1,
                              label: "Find <file> in Finder", bundleID: Self.finder, isOffered: true),
            RecallSource.Part(partID: "\(route)/block-1", kind: .subprocedure, firstPosition: 2, lastPosition: 6,
                              label: "Rotate <file> and export it", bundleID: Self.preview, isOffered: true),
            RecallSource.Part(partID: "\(route)/block-2", kind: .subprocedure, firstPosition: 7, lastPosition: 7,
                              label: "Keep Finder's preview shown", bundleID: Self.finder, isOffered: true),
        ]
        parts += steps.map {
            RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position, label: $0.label,
                              bundleID: $0.bundleID, isOffered: $0.isOffered)
        }
        return RecallSource(routeID: route, procedureLabel: "Find <file>, rotate it and export it", steps: steps, parts: parts,
                            parameters: [
                                parameter("criterion", "criterion", role: "text searched for the input file", observed: ["foto_demo"]),
                                parameter("name", "output_name", role: "name of the exported file without extension", observed: ["foto_web"]),
                                parameter("ext", "output_extension", role: "extension of the exported file", observed: ["jpg"]),
                                parameter("format", "output_format", role: "format chosen in the Export dialog", observed: ["JPEG"]),
                            ],
                            confirmedUses: 0)
    }

    static func value(_ name: String, _ text: String, role: String? = nil, kind: TaskValueKind = .text) -> TaskValue {
        try! TaskValue(name: name, role: role, kind: kind, content: .text(text), source: .request)
    }

    static let exportValues = [value("output_name", "foto_mail"), value("output_extension", "png"), value("output_format", "PNG")]

    static let thresholds = SelectionThresholds(absolute: 0.5, stepMargin: 0.05, partMargin: -0.2, adequacy: 0.05, tie: 0.02)

    /// Scores the steps (and, when given, the parts) of a source for one need.
    static func scored(_ source: RecallSource, steps: [Int: Double], parts: [String: Double] = [:], floor: Double = 0.1) -> ScoredSource {
        var stepRelevance: [Int: Double] = [:]
        var partRelevance: [String: Double] = [:]
        for step in source.steps {
            stepRelevance[step.position] = steps[step.position] ?? floor
            partRelevance[step.partID] = steps[step.position] ?? floor
        }
        for part in source.parts where part.kind != .step { partRelevance[part.partID] = parts[part.partID] ?? floor }
        return ScoredSource(source: source, stepRelevance: stepRelevance, partRelevance: partRelevance)
    }

    static func select(_ sources: [ScoredSource], need: String = "Export the photo as PNG", values: [TaskValue] = exportValues,
                       app: String? = nil, constraints: [String] = [], observed: Set<ObservedState> = [],
                       thresholds: SelectionThresholds = thresholds) -> NeedOutcome {
        RecallSelector.select(position: 0, need: try! RecallNeed(text: need, bundleID: app), sources: sources,
                              context: RecallSelector.Context(values: values, constraints: constraints, observed: observed),
                              thresholds: thresholds)
    }

    // MARK: Episodes

    @Test("a version is cut into episodes: a step that leaves its block's state unchanged, or from a dialog's opening to its closing")
    func episodes() {
        let units = Self.photo().units
        #expect(units.map(\.positions) == [0...0, 1...1, 2...2, 3...6, 7...7])
        #expect(units.allSatisfy { !$0.isUncertain })
        #expect(Self.photo().blocks == [0...1, 2...6, 7...7])
    }

    @Test("an episode whose start was not recorded in a known state is uncertain, step by step")
    func uncertainEpisodes() {
        let units = Self.photo(knownEntries: false).units
        // Finder's base state is unknown: its steps stand alone, the second uncertain. Preview's base is known; the
        // dialog's states were not recorded, so nothing says the menu's episode goes on or returns to the base.
        #expect(units.map(\.positions) == (0...7).map { $0...$0 })
        #expect(units.filter(\.isUncertain).map(\.positions.lowerBound) == [1, 4, 5, 6])
    }

    // MARK: Selection

    @Test("a need about the export gets the dialog's whole episode with the task's values, never the rotation done before")
    func exportTract() throws {
        let outcome = Self.select([Self.scored(Self.photo(), steps: [3: 0.8, 4: 0.7, 5: 0.75, 6: 0.6])])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 3...6)
        #expect(outcome.coverage == .complete)
        let bound = selected.requirements.filter { $0.kind == .parameterBound }
        #expect(Set(bound.compactMap(\.taskValueName)) == ["output_name", "output_extension", "output_format"])
        #expect(bound.allSatisfy { $0.bindingMatch == .name })
        #expect(selected.requirements.contains { $0.kind == .compatibilityUnknown && $0.stepPosition == 5 },
                "PNG was never chosen in the source")
        #expect(selected.requirements.first?.kind == .entryState && selected.requirements.first?.sceneID == "editing")
    }

    @Test("a need about one step inside a dialog still gets the whole episode: the dialog is opened and confirmed")
    func episodeNeverSplit() throws {
        let outcome = Self.select([Self.scored(Self.photo(), steps: [5: 0.9])], need: "Choose PNG as the format")
        #expect(try #require(outcome.selected).positions == 3...6)
    }

    @Test("a need about a step that leaves the state unchanged gets that step alone")
    func singleStep() throws {
        let outcome = Self.select([Self.scored(Self.photo(), steps: [2: 0.9], parts: ["photo/block-1": 0.95, "photo/procedure": 0.95])],
                                  need: "Rotate the open image to the right", values: [])
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 2...2, "the whole is not clearly more relevant than the step")
        #expect(outcome.coverage == .complete)
    }

    @Test("a whole part clearly more relevant than any of its steps is proposed, without a last episode the need does not ask for")
    func wholePart() throws {
        let values = Self.exportValues + [Self.value("criterion", "ritratto")]
        let outcome = Self.select([Self.scored(Self.photo(), steps: [2: 0.55, 3: 0.55], parts: ["photo/procedure": 0.9])],
                                  need: "Find ritratto, rotate it and export it", values: values)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 0...6, "showing Finder's preview afterwards is no part of the need")
        #expect(selected.requirements.filter { $0.kind == .applicationSwitch }.compactMap(\.stepPosition) == [2])
        let all = Self.select([Self.scored(Self.photo(), steps: [2: 0.55, 3: 0.55], parts: ["photo/procedure": 0.9])],
                              need: "Find ritratto, rotate it, export it and show the preview in Finder", values: values)
        #expect(all.selected?.positions == 0...7 && all.selected?.wholePartID == "photo/procedure")
    }

    @Test("nothing above the absolute threshold is an absence, not a weak proposal")
    func absence() {
        let outcome = Self.select([Self.scored(Self.photo(), steps: [3: 0.45])])
        #expect(outcome.coverage == .absent && outcome.selected == nil)
    }

    @Test("a step of the episode the catalogue does not offer is never delivered and leaves a gap")
    func notOffered() throws {
        let outcome = Self.select([Self.scored(Self.photo(offered: Set(0...7).subtracting([6])), steps: [3: 0.8, 4: 0.7, 5: 0.7])])
        let selected = try #require(outcome.selected)
        #expect(!selected.positions.contains(6))
        #expect(outcome.coverage == .partial && outcome.reason == .gaps)
        #expect(selected.requirements.contains { $0.kind == .prerequisiteOutOfCatalogue && $0.stepPosition == 6 })
    }

    @Test("an episode whose entry state was not recorded is a gap: partial")
    func unknownEntry() throws {
        let outcome = Self.select([Self.scored(Self.photo(knownEntries: false), steps: [0: 0.8])], need: "Search the file in Finder",
                                  values: [Self.value("criterion", "x")])
        #expect(try #require(outcome.selected).positions == 0...0)
        #expect(outcome.coverage == .complete, "the block's first step starts from where the source opened the application")
        let second = Self.select([Self.scored(Self.photo(knownEntries: false), steps: [1: 0.8])], need: "Select the file found", values: [])
        #expect(second.coverage == .partial && second.reason == .gaps)
        #expect(second.selected?.requirements.contains { $0.kind == .unknownEntryState } == true)
    }

    @Test("a parameter no value of the task binds leaves the selection ambiguous until the agent resolves it")
    func missingParameter() {
        let outcome = Self.select([Self.scored(Self.photo(), steps: [3: 0.8, 4: 0.7, 5: 0.7, 6: 0.6])],
                                  values: [Self.value("output_name", "foto_mail"), Self.value("output_extension", "png")])
        #expect(outcome.coverage == .ambiguous && outcome.reason == .unresolvedInput)
        #expect(outcome.selected?.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "format" } == true)
    }

    @Test("a need bound to an application sees only that application's steps")
    func boundToApplication() throws {
        let scored = Self.scored(Self.photo(), steps: [0: 0.9, 3: 0.7, 4: 0.6, 5: 0.6, 6: 0.6])
        let outcome = Self.select([scored], app: Self.preview)
        #expect(try #require(outcome.selected).positions == 3...6)
    }

    // MARK: Variants

    /// Two versions of one method that differ only in the item chosen: print all pages, print the current page.
    static func printing(_ route: String, item: String, label: String) -> RecallSource {
        let steps = [
            step(0, part: route, tool: .menu, [("path", text("File > Print…"))], bundle: Self.preview, entry: .state("pdf"),
                 exit: .state("print"), label: "Open the Print dialog"),
            step(1, part: route, tool: .select, [("control", text("Pages")), ("item", text(item))], bundle: Self.preview,
                 entry: .state("print"), label: label),
            step(2, part: route, tool: .press, [("button", text("Print"))], bundle: Self.preview, entry: .state("print"),
                 exit: .state("pdf"), label: "Confirm printing"),
        ]
        let parts = [RecallSource.Part(partID: "\(route)/procedure", kind: .procedure, firstPosition: 0, lastPosition: 2,
                                       label: "Print the open PDF", bundleID: Self.preview, isOffered: true)]
            + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                            label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: route, procedureLabel: "Print the open PDF", steps: steps, parts: parts, parameters: [],
                            confirmedUses: 0)
    }

    static var printSources: [ScoredSource] {
        [scored(printing("all", item: "All", label: "Choose to print all pages"), steps: [0: 0.8, 1: 0.8, 2: 0.8]),
         scored(printing("current", item: "Current", label: "Choose to print the current page only"), steps: [0: 0.8, 1: 0.8, 2: 0.8])]
    }

    @Test("tied variants of one method are an ambiguity when the need does not choose: both named, no detail delivered")
    func variantsAmbiguous() {
        let outcome = Self.select(Self.printSources, need: "Print the open PDF", values: [])
        #expect(outcome.coverage == .ambiguous && outcome.reason == .alternatives && outcome.selected == nil)
        #expect(Set(outcome.alternatives.map(\.routeID)) == ["all", "current"])
    }

    @Test("the need's words choose between variants: the side it names is selected")
    func variantsResolved() throws {
        #expect(try #require(Self.select(Self.printSources, need: "Print all the pages", values: []).selected).routeID == "all")
        #expect(try #require(Self.select(Self.printSources, need: "Print just the current page", values: []).selected).routeID == "current")
    }

    @Test("tied selections that are different methods are no ambiguity: either serves the need")
    func differentMethods() throws {
        var other = Self.printing("shortcut", item: "All", label: "Choose to print all pages")
        let steps = other.steps.map { step -> RecallSource.Step in
            guard step.position == 0 else { return step }
            return Self.step(0, part: "shortcut", tool: .pressKey, [("key", Self.text("p"))], bundle: Self.preview, entry: .state("pdf"),
                             exit: .state("print"), label: "Open the Print dialog with its shortcut")
        }
        other = RecallSource(routeID: "shortcut", procedureLabel: other.procedureLabel, steps: steps, parts: other.parts,
                             parameters: [], confirmedUses: 0)
        let outcome = Self.select([Self.printSources[0], Self.scored(other, steps: [0: 0.8, 1: 0.8, 2: 0.8])], need: "Print the PDF",
                                  values: [])
        #expect(outcome.coverage == .complete && outcome.selected != nil && outcome.alternatives.isEmpty)
    }

    @Test("a choice the method fixes while the task names another value for it excludes the method; the other variant is chosen")
    func fixedChoiceConflict() throws {
        let fixed = Self.printing("all", item: "All", label: "Choose which pages to print")
        let outcome = Self.select([Self.scored(fixed, steps: [0: 0.8, 1: 0.8, 2: 0.8])], need: "Print the PDF",
                                  values: [Self.value("pages", "Current", role: "pages to print")])
        #expect(outcome.selected == nil && outcome.coverage == .absent && outcome.reason == .excluded)
        let excluded = try #require(outcome.excluded.first)
        #expect(excluded.routeID == "all" && excluded.positions == 0...2 && excluded.role == .excluded)
        #expect(excluded.requirements.map(\.kind) == [.certainConflict] && excluded.requirements.first?.taskValueName == "pages")
        let both = Self.select(Self.printSources, need: "Print the PDF", values: [Self.value("pages", "Current", role: "pages to print")])
        #expect(both.selected?.routeID == "current" && both.coverage == .complete, "the incoherent variant is excluded, not an ambiguity")
        #expect(both.excluded.map(\.routeID) == ["all"])
    }

    @Test("a fixed JPEG choice is a certain conflict with a required PNG: the fragment is excluded, not delivered as ambiguous")
    func fixedIncompatibilityIsExcluded() {
        let step = Self.step(0, part: "fixed", tool: .select, [("control", Self.text("Format")), ("item", Self.text("JPEG"))],
                             bundle: Self.preview, entry: .state("dialog"), exit: .state("dialog"), label: "Choose JPEG format")
        let source = RecallSource(routeID: "fixed", procedureLabel: "Choose JPEG format", steps: [step], parts: [
            .init(partID: "fixed/procedure", kind: .procedure, firstPosition: 0, lastPosition: 0, label: "Choose JPEG format",
                  bundleID: Self.preview, isOffered: true),
            .init(partID: step.partID, kind: .step, firstPosition: 0, lastPosition: 0, label: step.label, bundleID: Self.preview,
                  isOffered: true),
        ], parameters: [], confirmedUses: 0)
        let outcome = Self.select([Self.scored(source, steps: [0: 0.9])], need: "Choose PNG as the output format",
                                  values: [Self.value("output_format", "PNG", role: "format")])
        #expect(outcome.selected == nil, "R47 excludes a known incompatibility; missing information is a separate case")
        #expect(outcome.coverage == .absent && outcome.reason == .excluded)
        #expect(outcome.excluded.first?.requirements.contains { $0.kind == .certainConflict && $0.taskValueName == "output_format" } == true)
    }

    // MARK: Binding

    @Test("a parameter takes the task's value of its name, else of its role, else a derived value of a file; never a guess")
    func binding() {
        let name = Self.parameter("n", "output_name", role: "name of the exported file without extension")
        func bind(_ parameter: RecallSource.Parameter, _ values: [TaskValue]) -> RecallBinding.Outcome {
            RecallBinding.bind(parameter, among: RecallBinding.candidates(values))
        }
        guard case .bound(let byName, .name) = bind(name, [Self.value("output_name", "a")]) else { Issue.record("not by name"); return }
        #expect(byName.text == "a")
        guard case .bound(let byRole, .role) = bind(name, [Self.value("x", "b", role: "name of the exported file without extension")]) else {
            Issue.record("not by role"); return
        }
        #expect(byRole.text == "b")
        let file = Self.value("exported", "/Users/me/Desktop/foto_mail.png", role: "the exported file", kind: .file)
        guard case .bound(let derived, .derived) = bind(Self.parameter("e", "ext", role: "extension of the exported file"), [file]) else {
            Issue.record("not derived"); return
        }
        #expect(derived.text == "png")
        #expect(bind(name, [Self.value("x", "b", role: "name of the exported file without extension"),
                            Self.value("y", "c", role: "name of the exported file without extension")]) == .ambiguous(["x", "y"]))
        #expect(bind(name, [Self.value("recipient", "anna@example.com")]) == .missing)
        #expect(bind(Self.parameter("f", "folder", role: "destination folder", kind: .folder), [Self.value("folder", "Desktop")]) == .missing,
                "a text is not a folder")
    }

    @Test("the searched text masks the task's values by name, whole words only, the longest first")
    func masking() {
        let values = [Self.value("file_name", "report_q3.pdf", kind: .file), Self.value("recipient", "luca@example.com"),
                      Self.value("sort_column", "Total"), Self.value("x", "ab")]
        #expect(RecallText.masked("Email report_q3.pdf to luca@example.com", values: values) == "Email <file_name> to <recipient>")
        #expect(RecallText.masked("Find report_q3 in Finder", values: values) == "Find <file_name> in Finder", "a file's name is a value")
        #expect(RecallText.masked("Ordina per Totale, poi per Total", values: values) == "Ordina per Totale, poi per <sort_column>")
        #expect(RecallText.masked("ab cd", values: values) == "ab cd", "values shorter than three characters stay")
        #expect(RecallText.masked("Esporta il file", values: []) == "Esporta il file")
    }

    // MARK: Use linking

    @Test("calls are linked in order to the steps they carry out, skipping none silently; the agent's own calls stay its own")
    func linking() {
        let steps = Array(Self.photo().steps[3...6])
        let values = ["name": "foto_mail", "ext": "png", "format": "PNG"]
        let calls: [RecallUseLinking.Call] = [
            .init(eventID: "c1", request: .menu(path: "File > Export…"), checkPassed: true, bundleID: Self.preview, entry: .state("editing")),
            .init(eventID: "c2", request: .observe(full: false), checkPassed: true, bundleID: Self.preview),
            .init(eventID: "c3", request: .typeText(target: "foto_demo.png", text: "foto_mail.png", section: nil, replace: true),
                  checkPassed: true, bundleID: Self.preview, entry: .state("dialog")),
            .init(eventID: "c4", request: .press(button: "Save"), checkPassed: false, bundleID: Self.preview, entry: .state("dialog")),
        ]
        // The template step reads `replace` too: the source's call gave it.
        let typed = RecallSource.Step(position: 4, partID: "photo/step-4", label: nil, bundleID: Self.preview, tool: .typeText,
                                      arguments: steps[1].arguments + [OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true)))],
                                      entry: .state("dialog"), isOffered: true)
        let links = RecallUseLinking.link(steps: [steps[0], typed, steps[2], steps[3]], calls: calls, values: values)
        #expect(links.map(\.stepPosition) == [3, nil, 4, 6], "the observation is the agent's own; the format step was skipped")
        #expect(links.map(\.confirmed) == [true, false, true, false])
        let wrong = RecallUseLinking.link(steps: [typed], calls: [
            .init(eventID: "c5", request: .typeText(target: "foto_demo.png", text: "foto_web.jpg", section: nil, replace: true),
                  checkPassed: true, bundleID: Self.preview, entry: .state("dialog")),
        ], values: values)
        #expect(wrong.map(\.stepPosition) == [nil], "the episode's value is not the bound one")
        let choice = RecallUseLinking.link(steps: [steps[2]], calls: [
            .init(eventID: "c6", request: .select(control: "format", item: "png"), checkPassed: true, bundleID: Self.preview,
                  entry: .state("dialog")),
        ], values: values)
        #expect(choice.map(\.stepPosition) == [5], "a control and an item the application shows compare without case")
    }
}
