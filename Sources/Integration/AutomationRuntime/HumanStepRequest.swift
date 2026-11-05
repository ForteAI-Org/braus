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

/// HumanStepResult carries minimized text and, when safe to disclose, pictures: the crop of a canvas before and after.
/// The session refuses requests outside the resumed turn; callers must not persist this history.
nonisolated public struct HumanStepResult: Sendable {
    /// One encoded picture and its media type, such as `image/png`.
    public struct Image: Sendable, Equatable {
        public let data    : Data
        public let mimeType: String

        public init(
            data    : Data,
            mimeType: String
        ) {
            self.data     = data
            self.mimeType = mimeType
        }
    }

    public let text: String
    public let images: [Image]
    public let isError: Bool

    public init(text: String, images: [Image] = [], isError: Bool = false) {
        self.text = text
        self.images = images
        self.isError = isError
    }

    public static var unavailable: Self {
        Self(text: "Human details are unavailable outside the resumed turn.", isError: true)
    }
}
