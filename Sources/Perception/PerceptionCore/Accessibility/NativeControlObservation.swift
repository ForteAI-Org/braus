import CoreGraphics
import Foundation

/// NativeControlObservation identifies one native harvest and the surface it was asked to read.
/// A nil window number means geometry-only matching, not an attested capture recipient.
/// The UUID identifies a read, not an authorization, stable element identity or atomic snapshot.
/// Consumers must match the expected live observation before qualifying any state from its facts.
public struct NativeControlObservation: Sendable, Equatable, Codable {

    public let observationID: UUID
    public let processID: Int32
    public let windowNumber: Int?
    public let windowFrame: CGRect

    public init(
        observationID: UUID,
        processID: Int32,
        windowNumber: Int?,
        windowFrame: CGRect
    ) {
        self.observationID = observationID
        self.processID = processID
        self.windowNumber = windowNumber
        self.windowFrame = windowFrame
    }
    /// Stable target facts omit the per-read UUID, but preserve owner, recipient and exact geometry.
    public struct Scope: Sendable, Equatable, Hashable {
        let processID: Int32
        let windowNumber: Int?
        let frameBits: [UInt64]
    }

    public var scope: Scope {
        Scope(processID: processID, windowNumber: windowNumber, frameBits: [
            Double(windowFrame.minX).bitPattern, Double(windowFrame.minY).bitPattern,
            Double(windowFrame.width).bitPattern, Double(windowFrame.height).bitPattern,
        ])
    }

}
