import Foundation
@testable import Memory
import Testing

@Suite("Recall binding requires coherent identity and unit evidence")
struct RecallBindingSafetyTests {

    private func parameter(
        _ name: String,
        role: String = "",
        kind: TaskValueKind = .text,
        unit: String? = nil
    ) -> RecallSource.Parameter {
        RecallSource.Parameter(
            parameterID: "parameter", name: name, role: role, kind: kind,
            direction: .input, unit: unit, observedValues: ["old value"]
        )
    }

    private func value(
        _ name: String,
        _ text: String,
        role: String? = nil,
        kind: TaskValueKind = .text,
        source: TaskValueSource = .request
    ) throws -> TaskValue {
        try TaskValue(
            name: name, role: role, kind: kind, content: .text(text), source: source,
            sourceRef: source == .previousOutput ? "previous/output" : nil
        )
    }

    private func bind(_ parameter: RecallSource.Parameter, _ values: [TaskValue]) -> RecallBinding.Outcome {
        RecallBinding.bind(parameter, among: RecallBinding.candidates(values))
    }

    @Test("normalized name collisions remain ambiguous in both input orders and across kinds")
    func normalizedCollision() throws {
        for kind in [TaskValueKind.text, .number] {
            let values = try [value("Track Name", "first"), value("track_name", "second", kind: kind)]
            for ordered in [values, Array(values.reversed())] {
                #expect(bind(parameter("track_name"), ordered) == .ambiguous(["Track Name", "track_name"]))
            }
        }
    }

    @Test("a conflicting explicit role cannot be overridden by an exact name or another candidate")
    func explicitRoleConflict() throws {
        let values = try [
            value("file", "source.pdf", role: "source file", kind: .file),
            value("destination", "output.pdf", role: "destination file", kind: .file),
        ]
        #expect(bind(parameter("file", role: "destination file", kind: .file), values) == .missing)
    }

    @Test("shared words, synonyms, and truncated word prefixes never assign a value")
    func similarityIsNotIdentity() throws {
        #expect(bind(parameter("new_track_timebase", role: "timebase of new track"),
                     [try value("new_track_name", "Recall Audio", role: "name of new track")]) == .missing)
        #expect(bind(parameter("layer_name", role: "name of layer"),
                     [try value("sheet_name", "New", role: "name of sheet")]) == .missing)
        #expect(bind(parameter("heading"), [try value("title", "New")]) == .missing)
        #expect(bind(parameter("duration"), [try value("durations", "2000")]) == .missing)
        #expect(bind(parameter("the_source"), [try value("source", "New")]) == .missing)
    }

    @Test("complete normalized names accept unseen values without using historical examples")
    func unseenValueAndFullNormalization() throws {
        let input = try value("NÉW_ＴＲＡＣＫ_name", "New Bass")
        guard case .bound(let bound, .name) = bind(parameter("new track name"), [input]) else {
            Issue.record("the complete normalized identity did not bind"); return
        }
        #expect(bound.text == "New Bass")
        #expect(!bound.isDerived)
    }

    @Test("role matches require unique input identity in either input order")
    func roleCollision() throws {
        let values = try [value("a", "New", role: "layer name"), value("b", "Other", role: "layer name")]
        for ordered in [values, Array(values.reversed())] {
            #expect(bind(parameter("name", role: "layer name"), ordered) == .ambiguous(["a", "b"]))
        }
        let collidingNames = try [
            value("Track Name", "New", role: "layer name"),
            value("track_name", "Other", role: "sheet name"),
        ]
        #expect(bind(parameter("name", role: "layer name"), collidingNames)
                == .ambiguous(["Track Name", "track_name"]))
    }

    @Test("previous sources cannot win a normalized collision against the current request")
    func sourceCollision() throws {
        let values = try [
            value("Name", "Previous", source: .previousOutput),
            value("name", "Current"),
        ]
        for ordered in [values, Array(values.reversed())] {
            #expect(bind(parameter("name"), ordered) == .ambiguous(["Name", "name"]))
        }
    }

    @Test("file derivation binds only the requested component of the coherent file role")
    func fileDerivation() throws {
        let input = try value("destination", "/Exports/New Bass.wav", role: "destination file", kind: .file)
        for (role, kind, text) in [
            ("name of destination file without extension", TaskValueKind.text, "New Bass"),
            ("extension of destination file", .text, "wav"),
            ("folder of destination file", .folder, "/Exports"),
        ] {
            guard case .bound(let bound, .derived) = bind(parameter("component", role: role, kind: kind), [input]) else {
                Issue.record("coherent file component did not bind: \(role)"); continue
            }
            #expect(bound.text == text)
        }
        #expect(bind(parameter("component", role: "extension of source file"), [input]) == .missing)
        #expect(bind(parameter("component", role: "extension of destination file", kind: .number), [input]) == .missing)
    }

    @Test("derived roles cannot choose between files or bypass a source identity collision")
    func derivedCollision() throws {
        let values = try [
            value("Source File", "/one.pdf", role: "source file", kind: .file),
            value("source_file", "/two.png", role: "another file", kind: .file),
        ]
        for ordered in [values, Array(values.reversed())] {
            #expect(bind(parameter("extension", role: "extension of source file"), ordered)
                    == .ambiguous(["Source File", "source_file"]))
        }
        let sameRole = try [
            value("one", "/one.pdf", role: "source file", kind: .file),
            value("two", "/two.png", role: "source file", kind: .file),
        ]
        #expect(bind(parameter("extension", role: "extension of source file"), sameRole)
                == .ambiguous(["one.extension", "two.extension"]))
    }

    @Test("numbers and references are not assigned to text merely because the name agrees",
          arguments: [TaskValueKind.number, .reference])
    func noTextCoercion(kind: TaskValueKind) throws {
        #expect(bind(parameter("name"), [try value("name", "2000", kind: kind)]) == .missing)
    }

    @Test("required units remain missing for every untyped quantity, with no implicit conversion",
          arguments: ["s", "ms", "frames", "samples", "24 fps", "25 fps", "%", "fraction", "px", "mm", "EUR", "cents"])
    func unitsAreUnknown(unit: String) throws {
        let requested = parameter("duration", role: "duration", kind: .number, unit: unit)
        for role in ["duration", "duration in milliseconds", "duration in \(unit)"] {
            #expect(bind(requested, [try value("duration", "2000", role: role, kind: .number)]) == .missing)
        }
    }

    @Test("legacy and unitless quantities retain the numeric contract without assuming a physical unit")
    func unitless() throws {
        let input = try value("count", "2", kind: .number)
        for unit in [nil, "", " \n"] as [String?] {
            guard case .bound(let bound, .name) = bind(parameter("count", kind: .number, unit: unit), [input]) else {
                Issue.record("unitless count did not bind"); continue
            }
            #expect(bound.text == "2")
        }
        #expect(bind(parameter("count", kind: .number), [try value("count", "2")]) == .missing)
    }
    @Test("a producer feed cannot bypass required units or an explicit current-input conflict",
          arguments: [true, false])
    func producerCannotBypassUnits(requiresUnit: Bool) throws {
        typealias S = RecallSelectionTests
        let app = "example.editor"
        let steps = [
            S.step(0, part: "quantity", tool: .observe, [], bundle: app, entry: .state("main"),
                   exit: .state("main"), label: "Measure duration"),
            S.step(1, part: "quantity", tool: .typeText,
                   [("target", S.text("Duration")), ("text", .parameter("duration"))], bundle: app,
                   entry: .state("main"), exit: .state("main"), label: "Apply duration"),
        ]
        let parts: [RecallSource.Part] = [
            .init(partID: "quantity/procedure", kind: .procedure, firstPosition: 0, lastPosition: 1,
                  label: "Measure and apply duration", bundleID: app, isOffered: true),
            .init(partID: "quantity/block", kind: .subprocedure, firstPosition: 0, lastPosition: 1,
                  label: "Measure and apply duration", bundleID: app, isOffered: true),
        ] + steps.map {
            .init(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                  label: $0.label, bundleID: app, isOffered: true)
        }
        let source = RecallSource(
            routeID: "quantity", procedureLabel: "Measure and apply duration", steps: steps, parts: parts,
            parameters: [
                .init(parameterID: "measurement", name: "measurement", role: "measurement", kind: .number,
                      direction: .output, unit: nil, observedValues: ["2000"], producedBy: steps[0].partID),
                .init(parameterID: "duration", name: "duration", role: "duration", kind: .number,
                      direction: .input, unit: requiresUnit ? "s" : nil, observedValues: ["2000"], origins: [
                        .init(source: .previousOutput, reference: "measurement", attemptID: "attempt",
                              taskID: "task", value: "2000"),
                      ]),
            ], confirmedUses: 0
        )
        var inputs = [try value("measurement", "2000", kind: .number)]
        if !requiresUnit {
            inputs.append(try value("duration", "Current conflicting value", role: "track name", kind: .text))
        }
        let outcome = S.select([S.scored(source, steps: [0: 0.1, 1: 0.9])],
                               need: "Apply duration", values: inputs)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 1...1)
        #expect(selected.requirements.contains { $0.kind == .parameterMissing && $0.parameterID == "duration" })
        #expect(!selected.requirements.contains { $0.kind == .parameterBound && $0.parameterID == "duration" })
        #expect(!selected.requirements.contains { $0.kind == .inputProduced && $0.parameterID == "duration" })
    }

}
