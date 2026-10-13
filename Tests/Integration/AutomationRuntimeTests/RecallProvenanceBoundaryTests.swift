//
//  RecallProvenanceBoundaryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
@testable import AutomationRuntime
import Memory
import Testing

/// RecallProvenanceBoundaryTests are the third independent review's counterexample of provenance (F12) through the tool and
/// SQLite, with the review's body and expectations unchanged.
@MainActor
@Suite("Third independent D3 review: UUID provenance through the producer", .serialized)
struct RecallProvenanceBoundaryTests {
    typealias P = ProcedureLearningTests

    @Test("A real earlier task/output reference survives the tool and SQL boundary")
    func internalReferenceMustRemainUsable() async throws {
        let session = P.photoSession(try W.directory())
        let tools = P.tools(session, stream: "third-review-provenance")
        _ = try await P.task(tools, #"{"operation":"begin","goal":"Register the already prepared invoice","recall":false}"#)
        let task = try #require(P.rows("SELECT task_id FROM memory_tasks", in: session).first)
        _ = try await P.task(tools, #"{"operation":"end","outcome":"completed","outputs":[{"name":"invoice_file","kind":"file","value":"/tmp/report.pdf","source":"observation"}]}"#)
        let reference = task + "/invoice_file"
        _ = try await P.task(tools, #"{"operation":"begin","goal":"Email the ready invoice","recall":false,"inputs":[{"name":"attachment","kind":"file","value":"/tmp/report.pdf","source":"previous_output","source_ref":"\#(reference)"}]}"#)
        let refs = try P.rows("SELECT source_ref FROM memory_task_values WHERE name = 'attachment'", in: session)
        #expect(refs == [reference], "The real task exists and declares this output; its provenance must remain usable")
        #expect(ValueMinimization().minimize(text: "sk-ant-1234567890abcdefghijklmnopqrstuvwxyz").0 == ValueMinimization.marker)
        await RecallLifecycleTests.close(session)
    }
}
