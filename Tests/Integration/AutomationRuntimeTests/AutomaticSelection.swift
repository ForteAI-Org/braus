//
//  AutomaticSelection.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationMCP
import Testing

/// AutomaticSelection runs a suite or a test under the automatic selector's control (`RecallSelectionControl`): the
/// suites that prove the selector itself, its comparisons and the lifecycle it was measured with through `memory_task`
/// begin and recall. The product's path, the agent's choice, needs no trait.
struct AutomaticSelection: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                                  performing function: @concurrent @Sendable () async throws -> Void) async throws {
        try await RecallSelectionControl.$automatic.withValue(true) { try await function() }
    }
}

extension Trait where Self == AutomaticSelection {
    /// The automatic selector answers begin and recall, as the control of a comparison or a regression test.
    static var automaticSelection: Self { AutomaticSelection() }
}
