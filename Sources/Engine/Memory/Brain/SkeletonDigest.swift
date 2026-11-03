import Foundation

/// SkeletonDigest is the 128-bit fingerprint of SceneSkeleton.canonical, stored as big-endian halves.
/// Equal skeletons have equal digests; the digest is a search key, never an identity.
public struct SkeletonDigest: Hashable, Sendable {
    public let high: UInt64
    public let low: UInt64

    public init(_ skeleton: SceneSkeleton) {
        let bytes = Digest16.of(skeleton.canonical)
        high = Self.half(bytes.prefix(8))
        low = Self.half(bytes.suffix(8))
    }

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        high = Self.half(bytes.prefix(8))
        low = Self.half(bytes.suffix(8))
    }

    public var bytes: Data {
        Data(
            [high, low].flatMap { half in
                stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: half >> $0) }
            }
        )
    }

    private static func half(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
