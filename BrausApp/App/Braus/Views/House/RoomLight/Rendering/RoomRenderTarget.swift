import Foundation

/// RoomRenderTarget supplies a weakly held room submission and its current scheduling priority.
/// Readiness includes the room's own in-flight and settle guards; a successful submission clears
/// readiness until its completion reaches the main actor.
@MainActor
protocol RoomRenderTarget: AnyObject {
    var canRenderQueuedFrame: Bool { get }
    var path: LightingPath? { get }
    var renderPriority: (visible: Bool, uniforms: Bool, top: CGFloat) { get }

    func renderQueuedFrame() -> Bool
}
