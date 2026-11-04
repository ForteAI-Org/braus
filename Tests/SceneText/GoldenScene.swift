import Foundation
import PerceptionCore

/// GoldenScene loads a recorded scene after its neutral delivery has been validated for import.
struct GoldenScene: Sendable {
    let role  : String
    let family: String
    let name  : String
    let scene : SceneSnapshot
    let textV1: String
    let textV2: String

    /// Loads only a structurally validated delivery with approved, hash-bound reviews.
    /// An explicit root supports negative loader tests without modifying bundled evidence.
    static func all(at suppliedRoot: URL? = nil) throws -> [GoldenScene] {
        let root: URL
        if let suppliedRoot {
            root = suppliedRoot
        } else {
            guard let resources = Bundle.module.resourceURL else {
                throw SceneTextFailure("Scene text resources are unavailable")
            }
            root = resources.appending(path: "Fixtures")
        }
        return try SceneTextDelivery.load(from: root)
    }

}

struct SceneTextFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}
