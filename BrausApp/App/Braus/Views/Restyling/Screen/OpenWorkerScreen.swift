//
//  OpenWorkerScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

private struct OpenWorkerScreenKey: EnvironmentKey {
    static let defaultValue: ((UUID) -> Void)? = nil
}

extension EnvironmentValues {

    /// What opens a worker's screen in its own window, set by the house's shell over its team; nil
    /// opens nothing.
    var openWorkerScreen: ((UUID) -> Void)? {
        get { self[OpenWorkerScreenKey.self] }
        set { self[OpenWorkerScreenKey.self] = newValue }
    }
}
