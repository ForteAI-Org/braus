import Foundation
import PerceptionCore

enum ReplaySamples {
    static let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func scene() -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "test.synthetic",
            appName: "Synthetic Editor",
            windowTitle: "Draft",
            viewportPixelSize: ViewportPixelSize(width: 400, height: 300),
            elements: (0..<12).map {
                SceneElement(id: "row\($0)", kind: .control, label: "Setting \($0)",
                             bounds: NormalizedRect(x: 0.1, y: Double($0) * 0.06, width: 0.4, height: 0.04))
            }
        )
    }

    static func delivery(_ revision: Int, since: Int? = nil, window: String = "first",
                         session: UUID? = ReplaySamples.session, text: String = "text") -> SceneDelivery {
        SceneDelivery(revision: revision, session: session, windowKey: window,
                      since: since, scene: scene(), savedText: text)
    }
}
