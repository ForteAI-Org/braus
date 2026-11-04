//
//  RecallProvenanceBoundaryTests.swift
//  Braus
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
        let memory = MemoryService.shared(for: session.directory)
        let producer = try TaskProducer(source: .app, streamID: "third-review-provenance")
        let previous = try await TaskChannel.begin(TaskRevisionContent(goal: "Register the already prepared invoice"),
            producer: producer, traceID: nil, memory: memory)
        let output = try TaskValue(name: "invoice_file", kind: .file, content: .text("/tmp/report.pdf"), source: .observation)
        _ = try await TaskChannel.checkpoint(previous,
            TaskCheckpointDraft(kind: .end, declared: .completed, outputs: [output]), producer: producer, memory: memory)
        let reference = previous.taskID + "/invoice_file"
        _ = try await P.task(tools, #"{"request":"Email the ready invoice","inputs":[{"name":"attachment","kind":"file","value":"/tmp/report.pdf","source":"previous_output","source_ref":"\#(reference)"}]}"#)
        let refs = try P.rows("SELECT source_ref FROM memory_task_values WHERE name = 'attachment'", in: session)
        #expect(refs == [reference], "The real task exists and declares this output; its provenance must remain usable")
        #expect(ValueMinimization().minimize(text: "sk-ant-1234567890abcdefghijklmnopqrstuvwxyz").0 == ValueMinimization.marker)
        await RecallLifecycleTests.close(session)
    }
}
