//
//  TextRecognizing.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// RecognizedText is one run of text a recognizer found, with its box in top-left image pixels.
public struct RecognizedText: Sendable, Equatable {

    public var text: String
    public var pixelBox: CGRect

    public init(text: String, pixelBox: CGRect) {
        self.text     = text
        self.pixelBox = pixelBox
    }
}

/// TextRecognitionAccuracy trades time for fidelity. `accurate` tells near-identical labels apart
/// by the digit that differs; `fast` garbles dense small text. A stored text and a later match must
/// use the same level.
public enum TextRecognitionAccuracy: Sendable, Equatable {
    case fast
    case accurate
}

/// TextRecognizing supplies the text runs in an image, in the image's own pixel space.
///
/// A conformer runs where it is called and returns when the image has been read; it holds no
/// reference to the image afterwards. A recognizer that cannot run at all throws; one that finds
/// nothing returns an empty array, which is a real answer.
public protocol TextRecognizing: Sendable {

    func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText]

    /// Reads the image as `recognizeText` does, for a caller that may be cancelled: a conformer
    /// whose read can be abandoned stops it when the calling task is cancelled and throws
    /// `CancellationError`, so a stop does not wait for a read nobody will use.
    func recognizeTextCancellably(in image: CGImage, accuracy: TextRecognitionAccuracy) async throws -> [RecognizedText]
}

extension TextRecognizing {

    /// A read that cannot be abandoned: it does not start for a task already cancelled, and runs
    /// to its end once started.
    public func recognizeTextCancellably(
        in image: CGImage,
        accuracy: TextRecognitionAccuracy
    ) async throws -> [RecognizedText] {
        try Task.checkCancellation()
        return try recognizeText(in: image, accuracy: accuracy)
    }
}
