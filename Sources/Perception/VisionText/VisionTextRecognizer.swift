//
//  VisionTextRecognizer.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import PerceptionCore
import Vision

/// VisionTextRecognizer fills `TextRecognizing` with Apple's Vision framework, tuned for UI labels
/// (Vision declares a `RecognizedText` of its own, so the core's type is qualified here)
/// rather than prose: no language correction, which hurts labels and slows the request.
///
/// It runs on the calling thread and needs no privacy grant and no network. Vision loads its
/// network on the first request of a process, about forty milliseconds; `warmUp()` pays that once,
/// off the main thread, so the first real frame does not.
///
/// The cancellable read does not keep a cancelled caller waiting: a stop of `braus chat` once waited
/// about sixteen seconds for the rest of a read before releasing the Seat.
public struct VisionTextRecognizer: TextRecognizing {

    public init() {}

    public func recognizeText(
        in image: CGImage,
        accuracy: PerceptionCore.TextRecognitionAccuracy
    ) throws -> [PerceptionCore.RecognizedText] {
        let request = Self.request(accuracy)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return Self.texts(of: request, in: image)
    }

    /// Reads as `recognizeText` does, through `AbandonableRead`: a cancelled caller is answered at
    /// once, the Vision request is cancelled, and a read Vision does not stop finishes unobserved.
    public func recognizeTextCancellably(
        in image: CGImage,
        accuracy: PerceptionCore.TextRecognitionAccuracy
    ) async throws -> [PerceptionCore.RecognizedText] {
        let read = VisionRead(image: image, request: Self.request(accuracy))
        return try await AbandonableRead.run {
            try VNImageRequestHandler(cgImage: read.image, options: [:]).perform([read.request])
            return Self.texts(of: read.request, in: read.image)
        } stop: {
            read.request.cancel()
        }
    }

    /// Loads Vision's text network on a tiny blank image. Idempotent; a failure here is harmless
    /// because the next real request loads it anyway.
    public static func warmUp() {
        let side = 32
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return }
        _ = try? VisionTextRecognizer().recognizeText(in: image, accuracy: .accurate)
    }

    private static func request(_ accuracy: PerceptionCore.TextRecognitionAccuracy) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accuracy == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        return request
    }

    private static func texts(of request: VNRecognizeTextRequest, in image: CGImage) -> [PerceptionCore.RecognizedText] {
        let context = WindowCoordinateContext(
            windowOrigin  : .zero,
            backingScale  : 1,
            imagePixelSize: CGSize(width: image.width, height: image.height)
        )
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return PerceptionCore.RecognizedText(
                text    : candidate.string,
                pixelBox: context.imagePixelRect(fromBottomLeftNormalized: observation.boundingBox)
            )
        }
    }
}

/// VisionRead carries one request and its image to the thread that reads them and to the
/// cancellation handler: Vision documents `cancel()` as the way to abort a running request.
private final class VisionRead: @unchecked Sendable {

    let image: CGImage
    let request: VNRecognizeTextRequest

    init(image: CGImage, request: VNRecognizeTextRequest) {
        self.image   = image
        self.request = request
    }
}
