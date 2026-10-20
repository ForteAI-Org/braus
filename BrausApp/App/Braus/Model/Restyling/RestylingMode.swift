//
//  RestylingMode.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// RestylingMode says whether the app opens the graphic restyling mockup
/// instead of the team window.
nonisolated enum RestylingMode {

    /// Whether this process was launched with `BRAUS_RESTYLING=1`.
    static var isRequested: Bool {
        isRequested(in: ProcessInfo.processInfo.environment)
    }

    /// Whether `environment` asks for the mockup: only the value 1 does.
    static func isRequested(in environment: [String: String]) -> Bool {
        environment["BRAUS_RESTYLING"] == "1"
    }
}
