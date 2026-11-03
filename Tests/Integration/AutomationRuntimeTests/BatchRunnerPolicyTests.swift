import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Switches
import Testing

extension BatchRunnerTests {
    private func policyAct(_ target: String, expect: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["operation": .string("act"), "target": .string(target)]
        if let expect { row["expect"] = expect }
        return .object(row)
    }

    private func policyAnswer(_ session: BatchTestSession, _ rows: [JSONValue]) async throws -> String {
        try await SwitchBoard.$testing.withValue(.init(values: ["batch": "v2", "task_cycle": "v2"])) {
            let result = try await AutomationTools(session: session).call("batch", .object([
                "session": .string(try #require(session.id).uuidString), "steps": .array(rows)
            ]))
            return String(decoding: try JSONValue.canonicalEncoder().encode(result), as: UTF8.self)
        }
    }

    @Test(arguments: [false, true])
    func committingStepAfterUnconfirmedNeverStarts(absent: Bool) async throws {
        let session = BatchTestSession()
        session.entry.elements.append(BatchPolicyTests.element("send", label: "Send"))
        let check: OperationCheck? = absent
            ? OperationCheck(condition: .structuralEffect, method: .sceneText, verdict: .failed, performed: .requested) : nil
        session.results = [ActOutcome(.foundActed, "first", scene: session.entry),
                           ActOutcome(.actedUnverified, "second", scene: session.entry, check: check)]
        let answer = try await policyAnswer(session, [policyAct("Next"),
            policyAct("Next", expect: .object(["element": .string("Next")])),
            policyAct("Send", expect: .object(["window": .string("Done")]))])
        #expect(session.targets == ["Next", "Next"])
        #expect(answer.contains("committing_after_unconfirmed"))
    }

    @Test func takeoverDuringEntryReadClosesCleanly() async throws {
        let session = BatchTestSession()
        let interruption = AutomationCallInterruption()
        session.onObserve = {
            interruption.interruptForHumanControl()
            throw CancellationError()
        }
        let answer = try await AutomationCallInterruption.$current.withValue(interruption) {
            try await policyAnswer(session, [policyAct("Next"), policyAct("Next")])
        }
        #expect(session.targets.isEmpty)
        #expect(answer.contains("person_in_control"))
        #expect(!answer.contains("CancellationError"))
    }

    @Test func missingCheckCannotAuthorizeCommittingStep() async throws {
        let session = BatchTestSession()
        session.suppliesChecks = false
        session.entry.elements.append(BatchPolicyTests.element("send", label: "Send"))
        let answer = try await policyAnswer(session, [policyAct("Next"),
            policyAct("Send", expect: .object(["window": .string("Done")]))])
        #expect(session.targets == ["Next"])
        #expect(answer.contains("committing_after_unconfirmed"))
    }

    @Test func liveRoleReclassifiesCommittingStep() async throws {
        let session = BatchTestSession()
        session.entry.elements.append(BatchPolicyTests.element("format", label: "Format", role: "AXRadioButton"))
        var changed = session.entry
        changed.elements[1].role = "AXButton"
        session.results = [ActOutcome(.foundActed, "first", scene: changed)]
        let answer = try await policyAnswer(session, [policyAct("Next"), policyAct("Format"), policyAct("Next")])
        #expect(session.targets == ["Next"])
        #expect(answer.contains("committing_not_last"))
    }

    @Test func anotherAppAndUnknownEntryIDNeverAct() async throws {
        let other = BatchTestSession()
        var scene = other.entry
        scene.bundleID = "other.app"
        other.results = [ActOutcome(.foundActed, "first", scene: scene)]
        #expect(try await policyAnswer(other, [policyAct("Next"), policyAct("Next")]).contains("other_app"))
        #expect(other.targets == ["Next"])
        let missing = BatchTestSession()
        #expect(try await policyAnswer(missing, [policyAct("Next"), policyAct("old|Missing")]).contains("target_missing"))
        #expect(missing.targets == ["Next"])
    }

    @Test func menuAndInlineGesturesUsePolicyRunner() async throws {
        let menu = BatchTestSession()
        _ = try await policyAnswer(menu, [.object(["operation": .string("menu"), "path": .string("File > New")]), policyAct("Next")])
        #expect(menu.targets == ["File > New", "Next"])
        let inline = BatchTestSession()
        let result = try await SwitchBoard.$testing.withValue(.init(values: ["batch": "v2", "task_cycle": "v2", "batch_form": "in_gestures"])) {
            try await AutomationTools(session: inline).call("act", .object([
                "session": .string(try #require(inline.id).uuidString), "target": .string("Next"),
                "then": .array([policyAct("Next")])
            ]))
        }
        #expect(inline.targets == ["Next", "Next"])
        #expect(String(decoding: try JSONValue.canonicalEncoder().encode(result), as: UTF8.self).contains("2. "))
    }

    @Test(arguments: [true, false])
    func absentRequiresExpectationAlreadyTrue(wasTrue: Bool) async throws {
        let session = BatchTestSession()
        let check = OperationCheck(condition: .structuralEffect, method: .sceneText, verdict: .failed, performed: .requested)
        session.results = [ActOutcome(.actedUnverified, "absent", scene: session.entry, check: check)]
        let answer = try await policyAnswer(session, [
            policyAct("Next", expect: .object(["element": .string(wasTrue ? "Next" : "Missing")])), policyAct("Next")
        ])
        #expect(session.targets.count == (wasTrue ? 2 : 1))
        if !wasTrue { #expect(answer.contains("expected_absent")) }
    }
}

extension BatchRunnerTests {
    @Test func policySchemaKeepsStepArgumentsOnBothSurfaces() throws {
        for surface in ["v1", "v2"] {
            try SwitchBoard.$testing.withValue(.init(values: ["batch": "v2", "expect": "off", "tool_surface": surface])) {
                let definitions = AutomationTools.definitions
                let batch = try #require(definitions.first { $0["name"].string == "batch" })
                let fields = batch["inputSchema"]["properties"]["steps"]["items"]["properties"]
                #expect(fields["expect"] != .null)
                #expect(fields["target"] != .null)
                #expect(fields["operation"]["enum"].array?.contains(.string("menu")) == true)
                for tool in definitions where tool["name"].string == "batch" {
                    let encoded = try JSONValue.canonicalEncoder().encode(tool["inputSchema"])
                    #expect((tool["description"].string ?? "").count + String(decoding: encoded, as: UTF8.self).count <= 4096)
                }
            }
            try SwitchBoard.$testing.withValue(.init(values: ["batch": "v2", "task_cycle": "v2", "batch_form": "in_gestures", "tool_surface": surface])) {
                for tool in AutomationTools.definitions where tool["inputSchema"]["properties"]["then"] != .null {
                    let encoded = try JSONValue.canonicalEncoder().encode(tool["inputSchema"])
                    #expect((tool["description"].string ?? "").count + String(decoding: encoded, as: UTF8.self).count <= 4096)
                }
            }
        }
    }
}


extension BatchRunnerTests {
    @Test func externalClientRejectsIncompatibleBatchBeforeReading() async throws {
        let session = BatchTestSession()
        try await SwitchBoard.$testing.withValue(.init(values: ["batch": "v2", "task_cycle": "v1"])) {
            let tools = AutomationTools(session: session)
            await #expect(throws: BatchConfigurationError.taskCycleV2Required) {
                _ = try await tools.call("batch", .object([
                    "session": .string(try #require(session.id).uuidString),
                    "steps": .array([.object(["operation": .string("act"), "target": .string("Next")])])
                ]))
            }
            #expect(session.reads == 0)
            #expect(session.targets.isEmpty)
            let refused = MCPRouter.failureResult(BatchConfigurationError.taskCycleV2Required)
            #expect(!String(describing: refused).contains("batch=v2 requires task_cycle=v2"))
        }
    }

    @Test func entryErrorWithheldFromAnswerAndModelText() async throws {
        let session = BatchTestSession()
        let secret = "sk-test-FAKE-123456789012345678901234567890"
        session.onObserve = { throw AutomationFailure("Failed with " + secret) }
        let answer = try await policyAnswer(session, [policyAct("Next"),
            .object(["operation": .string("insert_text"), "text": .string(secret)])])
        #expect(!answer.contains(secret))
        #expect(answer.contains("[withheld]"))
    }
}


extension BatchRunnerTests {
    @Test func finalUnknownCompletesWithoutInventingConfirmation() async throws {
        let session = BatchTestSession()
        session.suppliesChecks = false
        let answer = try await policyAnswer(session, [policyAct("Next")])
        #expect(session.targets == ["Next"])
        #expect(!answer.contains("unknown_without_next_target"))
        #expect(answer.contains("unknown"))
    }
}
