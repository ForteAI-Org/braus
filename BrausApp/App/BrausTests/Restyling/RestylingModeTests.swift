//
//  RestylingModeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("RestylingMode")
struct RestylingModeTests {

    @Test("Only the value 1 asks for the mockup")
    func onlyOneAsks() {
        #expect(RestylingMode.isRequested(in: ["BRAUS_RESTYLING": "1"]))
        #expect(!RestylingMode.isRequested(in: [:]))
        #expect(!RestylingMode.isRequested(in: ["BRAUS_RESTYLING": "0"]))
    }
}
