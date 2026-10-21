//
//  MockAccount.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// MockAccount is the simulated person signed in to the restyling mockup, whose monogram the
/// sidebar's foot shows.
nonisolated struct MockAccount: Sendable {
    let name : String
    let email: String

    /// The account of the design's prototypes.
    static let sample = MockAccount(
        name : "Eliomar Rodriguez",
        email: "eliomar@example.com"
    )

    /// The first letter of each word of the name, at most two, uppercased: "ER".
    var monogram: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
