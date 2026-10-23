//
//  IrreversibleRefusalTests.swift
//  Braus
//

@testable import EngineCore
import Testing

/// What a refusal of a destructive step tells the model: that the step is not authorized, never that it was
/// authorized and blocked, which agents then repeated to the person as "despite your authorization".
@Suite("Irreversible refusal wording")
struct IrreversibleRefusalTests {

    @Test("a route that cannot read the effect back says the step is not authorized in this session")
    func readBackRefusalIsNotAuthorization() {
        let text = IrreversiblePolicy.readBackRefusal("'Delete'")
        #expect(text.contains("not authorized in this session"))
        #expect(text.contains("cannot read its effect back"))
    }
}
