//
//  RoomLightView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit

/// RoomLightView shows one room lit by its worker, seen from above.
///
/// It renders only on demand: once when it appears or changes size, and once when `uniforms`
/// change. The busy flicker and the waiting breath are opacity animations on its layer, so a room at
/// rest costs compositing only; under Reduce Motion they do not run. The brows belong to a
/// `MascotFace` with `drawsBody` false placed over the sphere, a circle of 34% of the room's short
/// side at its centre.
final class RoomLightView: MTKView {

    /// What the room shows. Setting a different value draws the room once.
    var uniforms: RoomLightUniforms {
        didSet {
            guard uniforms != oldValue else { return }
            needsDisplay = true
            if uniforms.status != oldValue.status {
                updateAmbientMotion()
            }
        }
    }

    /// How the light is computed on this GPU, after `BRAUS_ROOM_LIGHT`.
    let path: LightingPath

    private let renderer: (any RoomRenderer)?

    init(
        device  : MTLDevice,
        uniforms: RoomLightUniforms,
        frame   : CGRect = .zero
    ) {
        let wanted = LightingPath.choose(
            supportsRaytracing: device.supportsRaytracing,
            override          : ProcessInfo.processInfo.environment["BRAUS_ROOM_LIGHT"]
        )
        // A ray tracer that cannot load falls back to the precomputed light.
        let tracer: RayTracedRoomRenderer? = wanted == .rayTraced ? RayTracedRoomRenderer(device: device) : nil
        renderer      = tracer ?? PrecomputedRoomRenderer(device: device)
        path          = tracer == nil ? .precomputed : .rayTraced
        self.uniforms = uniforms
        super.init(
            frame : frame,
            device: device
        )
        isPaused              = true
        enableSetNeedsDisplay = true
        // The kernels write the drawable's texture directly.
        framebufferOnly  = false
        colorPixelFormat = .bgra8Unorm
        colorspace       = CGColorSpace(name: CGColorSpace.sRGB)
        updateAmbientMotion()
    }

    required init(coder: NSCoder) { fatalError("RoomLightView is code-only") }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let drawable = currentDrawable else { return }
        renderer.render(
            uniforms,
            into: drawable,
            size: bounds.size
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAmbientMotion()
    }

    static let ambientKey = "ambient"

    /// Starts the busy flicker or the waiting breath on the layer's opacity, after the prototype's
    /// keyframes, or stops both for any other status and under Reduce Motion.
    private func updateAmbientMotion() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.ambientKey)
        guard !RestylingMotion.reducesMotion else { return }
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        switch uniforms.status {
        case .busy:
            let flicker = CAKeyframeAnimation(keyPath: "opacity")
            flicker.values          = [1, 0.8, 0.95, 1]
            flicker.keyTimes        = [0, 0.4, 0.55, 1]
            flicker.timingFunctions = [curve, curve, curve]
            flicker.duration        = RestylingTiming.roomFlicker
            flicker.repeatCount     = .infinity
            layer.add(
                flicker,
                forKey: Self.ambientKey
            )
        case .waiting:
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue      = 1
            breath.toValue        = 0.55
            breath.duration       = RestylingTiming.waitingBreath / 2
            breath.autoreverses   = true
            breath.repeatCount    = .infinity
            breath.timingFunction = curve
            layer.add(
                breath,
                forKey: Self.ambientKey
            )
        case .free, .off:
            break
        }
    }
}
