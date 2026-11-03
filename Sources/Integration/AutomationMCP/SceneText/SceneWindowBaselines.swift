import Foundation
import PerceptionCore

/// SceneWindowKey identifies a session's window, with title fallback kept in its readings.
nonisolated public struct SceneWindowKey: Sendable, Hashable {
    public let session: UUID?
    public let windowNumber: Int?
    public let bundleID: String
}

/// SceneWindowBaselines retains an anchor and the last reading, with at most one step from an anchored difference.
nonisolated struct SceneWindowBaselines: Sendable {
    struct Reading: Sendable {
        let revision: Int
        let scene: SceneSnapshot
    }
    let key: SceneWindowKey
    var anchor: Reading
    var last: Reading
    var lastBase: SceneAnswer.Base?
    var lastDependencies: Set<Int> = []

    var scene: SceneSnapshot { last.scene }

    func shows(_ scene: SceneSnapshot, number: Int?, in session: UUID) -> Bool {
        guard session == key.session, scene.bundleID == key.bundleID else { return false }
        if let number, let windowNumber = key.windowNumber { return number == windowNumber }
        return scene.windowTitle == self.scene.windowTitle
    }

    func mayShow(_ scene: SceneSnapshot, number: Int?, in session: UUID) -> Bool {
        guard session == key.session, scene.bundleID == key.bundleID,
              number == nil || key.windowNumber == nil else { return false }
        return (scene.windowTitle.isEmpty || self.scene.windowTitle.isEmpty)
            && scene.viewportPixelSize == self.scene.viewportPixelSize
    }
}
