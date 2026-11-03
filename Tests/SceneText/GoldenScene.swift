import Foundation
import PerceptionCore

/// GoldenScene loads a recorded scene after its neutral delivery has been validated for import.
struct GoldenScene: Sendable {
    let name  : String
    let scene : SceneSnapshot
    let textV1: String
    let textV2: String

    /// Loads all eight scenes without treating an absent delivery as an empty test set.
    /// Metadata validation must be connected to the supplied schema before importing fixtures.
    static func all() throws -> [GoldenScene] {
        guard let root = Bundle.module.resourceURL else {
            throw SceneTextFailure("Scene text resources are unavailable")
        }
        let fixtures = root.appending(path: "Fixtures")
        for name in ["manifest.json", "instance-checks.json"] {
            guard FileManager.default.fileExists(atPath: fixtures.appending(path: name).path) else {
                throw SceneTextFailure("SC0 delivery is incomplete: missing \(name)")
            }
        }
        let files = try FileManager.default.contentsOfDirectory(
            at                       : fixtures,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".scene.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count == 8 else {
            throw SceneTextFailure("SC0 delivery requires exactly eight recorded scenes")
        }
        return try files.map { file in
            let name = String(file.lastPathComponent.dropLast(".scene.json".count))
            let scene = try JSONDecoder().decode(SceneSnapshot.self, from: Data(contentsOf: file))
            let recorded = try Data(contentsOf: fixtures.appending(path: name + ".v1.txt"))
            guard recorded == Data(scene.text().utf8) else {
                throw SceneTextFailure("\(name): v1 differs from the attested neutral text; stop import")
            }
            let textV2 = try String(contentsOf: fixtures.appending(path: name + ".v2.txt"), encoding: .utf8)
            guard !textV2.isEmpty else { throw SceneTextFailure("\(name): expected v2 text is empty") }
            return GoldenScene(name: name, scene: scene, textV1: String(decoding: recorded, as: UTF8.self),
                               textV2: textV2)
        }
    }
}

struct SceneTextFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}
