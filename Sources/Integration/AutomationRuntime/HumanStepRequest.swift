//
//  HumanStepRequest.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation

/// HumanStepRequest selects retained details from the current resumed human-control turn.
nonisolated public enum HumanStepRequest: Sendable, Equatable {
    case steps(ClosedRange<Int>)
    case diff(String)
    case picture(Int)
}

/// HumanStepResult carries minimized text and, when safe to disclose, a retained HEIC picture.
/// The session refuses requests outside the resumed turn; callers must not persist this history.
nonisolated public struct HumanStepResult: Sendable {
    public let text: String
    public let picture: Data?
    public let isError: Bool

    public init(text: String, picture: Data? = nil, isError: Bool = false) {
        self.text = text
        self.picture = picture
        self.isError = isError
    }

    public static var unavailable: Self {
        Self(text: "Human details are unavailable outside the resumed turn.", isError: true)
    }
}
