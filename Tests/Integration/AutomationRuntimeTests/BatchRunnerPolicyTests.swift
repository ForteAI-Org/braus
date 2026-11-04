import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing

extension BatchRunnerTests {
    private func policyAct(_ target: String, expect: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["operation": .string("act"), "target": .string(target)]
        if let expect { row["expect"] = expect }
        return .object(row)
    }

    private func policyAnswer(_ session: BatchTestSession, _ rows: [JSONValue]) async throws -> String {
        let result = try await AutomationTools(session: session).call("batch", .object([
            "steps": .array(rows)
        ]))
        return String(decoding: try JSONValue.canonicalEncoder().encode(result), as: UTF8.self)
    }

    @Test(arguments: [false, true])
    func committingStepAfterUnconfirmedNeverStarts(absent: Bool) async throws {
        let session = BatchTestSession()
        session.entry.elements.append(BatchPolicyTests.element("send", label: "Send"))
        let check: OperationCheck? = absent
            ? OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .failed, performed: .requested) : nil
        session.results = [ActOutcome(.foundActed, "first", scene: session.entry),
                           ActOutcome(.actedUnverified, "second", scene: session.entry, check: check, noop: absent ? .statePresent : nil)]
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

    @Test func menuUsesTheSamePolicyRunner() async throws {
        let menu = BatchTestSession()
        _ = try await policyAnswer(menu, [.object(["operation": .string("menu"), "path": .string("File > New")]), policyAct("Next")])
        #expect(menu.targets == ["File > New", "Next"])
    }

    @Test func inlineContinuationIsRejectedBeforeAnyGesture() async throws {
        let session = BatchTestSession()
        var rejected = false
        do {
            let result = try await AutomationTools(session: session).call("act", .object([
                "target": .string("Next"), "then": .array([policyAct("Next")])
            ]))
            rejected = result["isError"].bool == true
        } catch { rejected = true }
        #expect(rejected)
        #expect(session.targets.isEmpty)
    }

    @Test(arguments: [true, false])
    func onlyTheOracleAlreadySatisfiedFactAllowsTheNextStep(wasTrue: Bool) async throws {
        let session = BatchTestSession()
        let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .failed, performed: .requested)
        session.results = [ActOutcome(.actedUnverified, "absent", scene: session.entry, check: check,
            noop: wasTrue ? .statePresent : nil)]
        let answer = try await policyAnswer(session, [
            policyAct("Next", expect: .object(["element": .string("Next")])), policyAct("Next")
        ])
        #expect(session.targets.count == (wasTrue ? 2 : 1))
        if !wasTrue { #expect(answer.contains("expected_absent")) }
    }
}

extension BatchRunnerTests {
    @Test func policySchemaKeepsItsOwnExpectationsWithGestureExpectDisabled() throws {
        do {
            let definitions = AutomationTools.definitions
            let batch = try #require(definitions.first { $0["name"].string == "batch" })
            let fields = batch["inputSchema"]["properties"]["steps"]["items"]["properties"]
            #expect(fields["expect"] != .null)
            #expect(fields["target"] != .null)
            #expect(fields["operation"]["enum"].array?.contains(.string("menu")) == true)
            #expect(definitions.allSatisfy { $0["inputSchema"]["properties"]["then"] == .null })
            let encoded = try JSONValue.canonicalEncoder().encode(batch["inputSchema"])
            #expect((batch["description"].string ?? "").count + String(decoding: encoded, as: UTF8.self).count <= 4096)
        }
    }
}

extension BatchRunnerTests {
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
