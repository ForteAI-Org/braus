//
//  NewLookTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation
import Testing
@testable import Braus

@MainActor
@Suite("The new look's setting")
struct NewLookTests {

    @Test("The new look is off until the person turns it on")
    func offByDefault() throws {
        let name     = "NewLookTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(!AppPreferences.newLookDefault)
        #expect(!AppPreferenceValues(defaults: defaults).newLook)

        defaults.set(
            true,
            forKey: AppPreferences.newLook
        )
        #expect(AppPreferenceValues(defaults: defaults).newLook)

        // As the launch argument `-restyling.newLook YES` gives it.
        defaults.set(
            "YES",
            forKey: AppPreferences.newLook
        )
        #expect(AppPreferenceValues(defaults: defaults).newLook)
    }
}
