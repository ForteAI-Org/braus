//
//  BodyMotionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import MetalFX
import QuartzCore
import SwiftUI
import Testing
import simd
@testable import Braus

@Suite("BodyMotion", .serialized)
@MainActor
struct BodyMotionTests {

    /// The grid's room, seen through the tilted camera.
    private static let size = CGSize(
        width : 127,
        height: 104
    )

    @Test("A loop's gestures become at most ten poses to bake, within the body's limits, larger than a nudge")
    func intentsBecomePoses() throws {
        let side = Float(Self.size.height)
        for status in [WorkerStatus.busy, .waiting, .free] {
            var widest = (turn: Float(0), hop: Float(0))
            for seed in UInt64(1)...12 {
                let loop   = WorkerBehaviour(status).loop(seed: seed)
                let found  = try #require(RoomBodyMotion(
                    loop : loop,
                    shape: .circle,
                    size : Self.size,
                    lean : 0
                ), "\(status) \(seed)")
                #expect(found.poses.count <= RoomBodyMotion.maxPoses, "\(status) \(seed)")
                for pose in found.poses {
                    #expect(abs(Double(pose.tilt)) <= BodyPose.maxTurn + 1e-6 && abs(Double(pose.lean)) <= BodyPose.maxTurn + 1e-6)
                    #expect(pose.hop >= 0 && Double(pose.hop) <= BodyPose.maxHop * Double(side) + 1e-4)
                    #expect(Double(abs(pose.shift)) <= BodyPose.maxMove * Double(side) + 1e-4)
                    #expect(Double(abs(pose.slide)) <= BodyPose.maxMove * Double(side) + 1e-4)
                    #expect(abs(Double(pose.stretch) - 1) <= BodyPose.maxStretch + 1e-6)
                    #expect(pose != .rest)
                    widest = (max(widest.turn, abs(pose.tilt), abs(pose.lean)), max(widest.hop, pose.hop / side))
                }
                // Every gesture leaves rest and comes back to it, in time, inside the loop.
                let times = found.keyframes.map(\.time)
                #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
                #expect(found.keyframes.first == RoomBodyMotion.Keyframe(time: 0, pose: nil))
                #expect(found.keyframes.last == RoomBodyMotion.Keyframe(time: loop.duration, pose: nil))
                #expect(found.duration == loop.duration)
                #expect(found.keyframes.contains { $0.pose != nil })
            }
            // Far from the first round's nudges of one or two degrees.
            #expect(widest.turn >= Float(5 * Double.pi / 180), "\(status): \(widest)")
            if status != .busy { #expect(widest.hop >= 0.03, "\(status): \(widest)") }
        }
    }

    @Test("Each state moves its own way, the body turning where the brows look")
    func bodyByState() {
        func poses(_ status: WorkerStatus) -> [BodyPose] {
            (UInt64(1)...30).flatMap { seed in
                WorkerBehaviour(status).loop(seed: seed).intents.flatMap { $0.keys.map(\.pose) }
            }
        }
        let free    = poses(.free)
        let waiting = poses(.waiting)
        let busy    = poses(.busy)
        #expect((free + waiting + busy).allSatisfy { $0.isAllowed })
        // Free looks around, shuffles aside, stretches, squats and bounces.
        #expect(free.contains { abs($0.tilt) >= 0.09 } && free.contains { $0.shift != 0 })
        #expect(free.contains { $0.stretch > 0.05 } && free.contains { $0.stretch < 0 } && free.contains { $0.hop > 0 })
        // Waiting leans toward the person, shifts its weight and hops when impatient.
        #expect(waiting.contains { $0.lean >= 0.07 && $0.slide > 0 } && waiting.contains { $0.shift != 0 })
        #expect(waiting.contains { $0.hop >= 0.04 })
        // Busy leans over its screen and bobs toward it.
        #expect(busy.contains { $0.lean > 0 && $0.tilt != 0 } && busy.contains { $0.lean >= 0.07 && $0.stretch < 0 })
        // Off only breathes.
        #expect((UInt64(1)...30).allSatisfy { WorkerBehaviour(.off).loop(seed: $0).intents.isEmpty })

        // A look turns the body the way the brows go; an impatient worker hops twice.
        var random = SystemRandomNumberGenerator()
        for action in [BrowAction.lookLeft, .lookRight, .shuffle, .shiftWeight] {
            let performance = action.performance(
                base  : .idle,
                random: &random
            )
            let look = performance.moves[0].left.dx
            let turn = performance.body.map(\.pose).first { $0.tilt != 0 || $0.shift != 0 }
            let way  = action == .shuffle ? turn?.shift ?? 0 : turn?.tilt ?? 0
            #expect(look * way > 0, "\(action): brows \(look), body \(way)")
        }
        let impatient = BrowAction.impatient.performance(
            base  : .asking,
            random: &random
        )
        #expect(impatient.body.filter { $0.pose.hop > 0 }.count == 2)
        let work = BrowAction.work.performance(
            base  : .working,
            random: &random
        )
        #expect(work.body.filter { $0.pose.stretch < 0 }.count >= 3)
    }

    @Test("Off, Reduce Motion, the view from above, an empty room and another status's loop move no body")
    func noMotion() {
        let busy    = Self.loop(.busy)
        let tilted  = Self.room(.busy)
        #expect(RoomLightView.bodyMotion(
            for          : busy,
            uniforms     : tilted,
            size         : Self.size,
            reducesMotion: false
        ) != nil)
        var top    = tilted
        top.camera = .top
        var empty  = tilted
        empty.hasOccupant = false
        let cases: [(WorkerBehaviourLoop?, RoomLightUniforms, Bool)] = [
            (busy, tilted, true),
            (WorkerBehaviour(.off).loop(seed: 3), Self.room(.off), false),
            (busy, top, false),
            (busy, empty, false),
            (Self.loop(.waiting), tilted, false),
            (nil, tilted, false),
        ]
        for (loop, uniforms, reducesMotion) in cases {
            #expect(RoomLightView.bodyMotion(
                for          : loop,
                uniforms     : uniforms,
                size         : Self.size,
                reducesMotion: reducesMotion
            ) == nil, "\(uniforms.status) \(uniforms.camera) \(uniforms.hasOccupant) \(reducesMotion)")
        }
        // A loop asleep has no gesture at all.
        for seed in UInt64(1)...20 {
            #expect(WorkerBehaviour(.off).loop(seed: seed).intents.isEmpty)
        }
    }

    @Test("The brows follow the face the camera shows on the moved body")
    func browsFollowTheFace() throws {
        let camera = RoomCamera.Perspective(size: Self.size)
        let rest   = camera.face(of: .circle).anchor
        let hop    = camera.face(
            of  : .circle,
            pose: RoomLightUniforms.Pose(hop: 3)
        ).anchor
        let right  = camera.face(
            of  : .circle,
            pose: RoomLightUniforms.Pose(tilt: 0.05)
        ).anchor
        #expect(hop.dy < rest.dy - 1, "a hop lifts the brows: \(hop) against \(rest)")
        #expect(abs(hop.dx - rest.dx) < 1e-6)
        #expect(right.dx > rest.dx + 0.5, "a tilt to the right takes them right: \(right) against \(rest)")

        let loop   = Self.loop(.waiting)
        let motion = try #require(RoomBodyMotion(
            loop : loop,
            shape: .circle,
            size : Self.size,
            lean : 0
        ))
        // The layer turns and scales about the room's centre; the shift lands the brows on the face.
        for (pose, move) in zip(motion.poses, motion.faceMoves) {
            let moved = camera.face(
                of  : .circle,
                pose: pose
            ).anchor
            let from  = (x: rest.dx, y: -rest.dy)
            let landed = CGPoint(
                x: move.scale * (from.x * cos(move.turn) - from.y * sin(move.turn)) + move.shift.x,
                y: move.scale * (from.x * sin(move.turn) + from.y * cos(move.turn)) + move.shift.y
            )
            #expect(abs(landed.x - moved.dx) < 1e-9 && abs(landed.y + moved.dy) < 1e-9, "\(pose)")
        }
        let follow = motion.browMotion()
        #expect(Set(follow.keys) == Set(RoomBodyMotion.browKeys))
        let shift  = try #require(follow[MascotLayer.bodyKey])
        #expect(shift.isAdditive)
        #expect(shift.repeatCount == .infinity)
        let values = try #require(shift.values as? [NSValue]).map(\.pointValue)
        for (keyframe, value) in zip(motion.keyframes, values) {
            #expect(value == (keyframe.pose.map { motion.faceMoves[$0].shift } ?? .zero))
        }
        // A turned body turns its brows the same way on screen.
        let turned = camera.face(
            of  : .circle,
            pose: RoomLightUniforms.Pose(tilt: 0.1)
        )
        #expect(turned.turn < camera.face(of: .circle).turn)
        // At the top of a hop the outline rises; every outline has the same points, so it morphs.
        let index = try #require(motion.poses.indices.max { motion.poses[$0].hop < motion.poses[$1].hop })
        let still = motion.outline(.rest).boundingBoxOfPath
        let lift  = motion.outline(motion.poses[index]).boundingBoxOfPath
        #expect(lift.maxY > still.maxY + 0.3 * CGFloat(motion.poses[index].hop))
        #expect(abs(lift.midX - still.midX) < 0.5)
        func count(_ path: CGPath) -> Int {
            var points = 0
            path.applyWithBlock { _ in points += 1 }
            return points
        }
        #expect(motion.poses.allSatisfy { count(motion.outline($0)) == count(motion.outline(.rest)) })
    }

    @Test("A posed body stands where its pose puts it: a hop lifts it and a tilt leans its top")
    func posedBodyHits() throws {
        let device  = try #require(MTLCreateSystemDefaultDevice())
        let room    = Self.room(.busy)
        let column  = stride(from: 0.0, to: Double(Self.size.height), by: 0.5).map {
            SIMD2(Float(Self.size.width / 2), Float($0))
        }
        func top(_ uniforms: RoomLightUniforms) throws -> Int {
            let hits = try RoomCameraTests.tiltedBodyHits(
                uniforms,
                at    : column,
                size  : Self.size,
                device: device
            )
            return try #require(hits.firstIndex(of: true))
        }
        var hopped  = room
        hopped.pose = RoomLightUniforms.Pose(hop: 4)
        let rest    = try top(room)
        #expect(try top(hopped) < rest - 3, "a hop lifts the body's top")

        // A row a little below the top: its hits move right as the body leans right.
        let y    = Float(rest) * 0.5 + 3
        let row  = stride(from: 0.0, to: Double(Self.size.width), by: 0.5).map { SIMD2(Float($0), y) }
        func middle(_ uniforms: RoomLightUniforms) throws -> Double {
            let hits = try RoomCameraTests.tiltedBodyHits(
                uniforms,
                at    : Array(row.prefix(254)),
                size  : Self.size,
                device: device
            )
            let xs = hits.indices.filter { hits[$0] }.map { Double(row[$0].x) }
            try #require(!xs.isEmpty)
            return xs.reduce(0, +) / Double(xs.count)
        }
        var leaning  = room
        leaning.pose = RoomLightUniforms.Pose(tilt: 0.06)
        #expect(try middle(leaning) > middle(room) + 0.75)
    }

    @Test("The body's shadow follows its hop, on the precomputed path and the denoised ray tracer")
    func shadowFollows() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var renderers: [any RoomRenderer] = [try #require(PrecomputedRoomRenderer(device: device))]
        let size = CGSize(
            width : 254,
            height: 208
        )
        var tracer: RayTracedRoomRenderer?
        if #available(macOS 26, *), MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device),
           let traced = RayTracedRoomRenderer(
               device  : device,
               denoises: true
           ) {
            traced.prepareDenoiser(
                pixelSize: size,
                camera   : .tilted
            )
            try await Self.until { traced.denoisedPixelSize != nil }
            renderers.append(traced)
            tracer = traced
        }
        defer { tracer?.releaseDenoiser() }
        // The floor the camera sees nearest the body's foot, where its contact shadow falls: lifted, the
        // body leaves it lighter. On the denoised path only the traced mesh shades the floor.
        let perspective = RoomCamera.Perspective(size: size)
        let radius      = Double(RoomLightUniforms.Shape(size: size).sphereRadius)
        let near        = perspective.project(SIMD3(size.width / 2, perspective.bodyDepth + 0.6 * radius, 0))
        let far         = perspective.project(SIMD3(size.width / 2, perspective.bodyDepth + 0.9 * radius, 0))
        let rows        = Int(near.y.rounded(.up))...Int(far.y)
        for renderer in renderers {
            var hopped  = Self.room(.waiting)
            hopped.pose = RoomLightUniforms.Pose(hop: 10)
            try await Self.until { tracer?.denoisedPixelSize != nil || tracer == nil }
            let still   = try Self.render(
                Self.room(.waiting),
                with  : renderer,
                device: device,
                size  : size
            )
            try await Self.until { tracer?.denoisedPixelSize != nil || tracer == nil }
            let lifted  = try Self.render(
                hopped,
                with  : renderer,
                device: device,
                size  : size
            )
            let shaded = rows.map { still.luma(Int(near.x), $0) }.reduce(0, +)
            let lit    = rows.map { lifted.luma(Int(near.x), $0) }.reduce(0, +)
            #expect(shaded + Double(rows.count) < lit, "\(type(of: renderer)): \(shaded) against \(lit)")
        }
    }

    @Test("A tilted room bakes its worker's poses after its render and plays them on the brows' clock")
    func roomBakesAndPlays() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let window   = Self.window()
        defer { window.close() }
        let uniforms = Self.room(.busy)
        let view     = RoomLightView(
            device  : device,
            uniforms: uniforms,
            frame   : CGRect(
                origin: .zero,
                size  : Self.size
            )
        )
        let mascot = Self.mascot(
            .busy,
            in: window
        )
        let link = RoomBodyLink()
        link.browsDidBehave(mascot)
        link.room = view
        window.contentView?.addSubview(view)
        let loop   = try #require(mascot.behaviour)
        let motion = try #require(RoomLightView.bodyMotion(
            for          : loop,
            uniforms     : uniforms,
            size         : Self.size,
            reducesMotion: false
        ))
        try await Self.until { view.bodyLayer.animation(forKey: RoomLightView.bodyKey) != nil }

        #expect(view.bodyMotion == motion)
        // A busy light pulses: each pose has its frame at full light and at the pulse's dimmest.
        #expect(motion.poses.allSatisfy { view.bodyFrames[$0]?.count == 2 })
        #expect(view.bodyRenders >= motion.poses.count)
        let envelope = try #require(view.bodyLayer.animation(forKey: RoomLightView.bodyKey) as? CAKeyframeAnimation)
        #expect(abs(envelope.beginTime - view.bodyLayer.convertTime(link.start, from: nil)) < 1e-6)
        #expect(envelope.duration == loop.duration)
        #expect(envelope.repeatCount == .infinity)
        #expect(view.bodyLit.animation(forKey: RoomLightView.bodyKey) != nil)
        #expect(view.bodyDim.animation(forKey: RoomLightView.bodyKey) != nil)
        #expect(view.bodyLit.animation(forKey: RoomLightView.pulseKey) != nil)

        // The brows follow the face's shift, from the same start.
        let follow = try #require(mascot.animation(forKey: MascotLayer.bodyKey) as? CAKeyframeAnimation)
        #expect(abs(follow.beginTime - mascot.convertTime(link.start, from: nil)) < 1e-6)
        #expect(follow.isAdditive)
        let shifts = try #require(follow.values as? [NSValue]).map(\.pointValue)
        #expect(shifts == motion.keyframes.map { $0.pose.map { motion.faceMoves[$0].shift } ?? .zero })

        // A resize shows the body at rest, with the brows on it.
        view.setFrameSize(CGSize(
            width : 140,
            height: Self.size.height
        ))
        view.layoutSubtreeIfNeeded()
        try await Self.until {
            view.bodyLayer.animation(forKey: RoomLightView.bodyKey) == nil
                && mascot.animation(forKey: MascotLayer.bodyKey) == nil
        }
        #expect(view.bodyLayer.isHidden)
    }

    @Test("Under Reduce Motion a tilted room bakes nothing and its brows stay on the body")
    func reduceMotionBakesNothing() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let view   = RoomLightView(
            device  : device,
            uniforms: Self.room(.waiting),
            frame   : CGRect(
                origin: .zero,
                size  : Self.size
            )
        )
        let mascot = Self.mascot(
            .waiting,
            in: window
        )
        let link = RoomBodyLink()
        link.browsDidBehave(mascot)
        link.room = view
        window.contentView?.addSubview(view)
        try await Self.until { view.renderCounts.full >= 1 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.bodyMotion == nil)
        #expect(view.bodyRenders == 0)
        #expect(view.bodyLayer.animation(forKey: RoomLightView.bodyKey) == nil)
        #expect(mascot.animation(forKey: MascotLayer.bodyKey) == nil)
    }

    @Test("A portrait's outline clips the room and moves with the body")
    func outlineMoves() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let side   = HouseWorkerPortrait.sceneSide(for: HouseWorkerPortrait.rowSize)
        let size   = CGSize(
            width : side,
            height: side
        )
        let room   = RoomLightUniforms(
            status     : .free,
            shape      : .circle,
            hasOccupant: true,
            camera     : .tilted,
            lean       : HouseWorkerPortrait.lean
        )
        let view = RoomLightView(
            device  : device,
            uniforms: room,
            frame   : CGRect(
                origin: .zero,
                size  : size
            )
        )
        view.silhouette = HouseWorkerPortrait.silhouette(
            of  : .circle,
            side: side
        ).cgPath
        let mascot = Self.mascot(
            .free,
            in: window
        )
        let link = RoomBodyLink()
        link.browsDidBehave(mascot)
        link.room = view
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let mask = try #require(view.bodyMask)
        #expect(view.layer?.mask === mask)
        // The layer's y points up, as MascotLayer places the brows: the outline holds them there.
        let face = try #require(RoomCamera.tilted.face(
            of  : .circle,
            in  : size,
            lean: HouseWorkerPortrait.lean
        ))
        #expect(mask.path?.contains(CGPoint(
            x: size.width / 2 + face.anchor.dx,
            y: size.height / 2 - face.anchor.dy
        )) == true)
        try await Self.until { mask.animation(forKey: RoomLightView.bodyKey) != nil }
        // A light that holds still bakes one frame per pose.
        let motion = try #require(view.bodyMotion)
        #expect(motion.poses.allSatisfy { view.bodyFrames[$0]?.count == 1 })
        #expect(view.bodyDim.isHidden)
    }

    @Test("A room in the grid joins its brows to its body, and an empty room, its worker away in chat, moves none")
    func gridRoomMoves() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let id = try #require((1...99).lazy.compactMap {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))
        }.first { !WorkerBehaviour(.busy).loop(seed: WorkerBehaviour.seed(for: $0)).intents.isEmpty })
        let worker = MockWorker(
            id      : id,
            name    : "Test",
            status  : .busy,
            activity: "Working",
            role    : "Tester",
            category: .general,
            shape   : .circle,
            badge   : nil
        )
        let window = Self.window()
        defer { window.close() }
        let host = NSHostingView(rootView: HouseRoomCell(
            worker    : worker,
            isSelected: false,
            camera    : .tilted
        ))
        host.frame = CGRect(
            origin: .zero,
            size  : Self.size
        )
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let room   = try #require(Self.views(RoomLightView.self, in: host).first)
        let mascot = try #require(Self.views(MascotFace.HostView.self, in: host).first?.mascot)
        try await Self.until {
            room.bodyLayer.animation(forKey: RoomLightView.bodyKey) != nil
                && mascot.animation(forKey: MascotLayer.bodyKey) != nil
        }
        #expect(room.bodyLink?.mascot === mascot)

        host.rootView = HouseRoomCell(
            worker    : worker,
            isSelected: true,
            camera    : .tilted
        )
        host.layoutSubtreeIfNeeded()
        try await Self.until { room.bodyLayer.animation(forKey: RoomLightView.bodyKey) == nil }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(room.bodyMotion == nil)
        #expect(room.bodyLayer.animation(forKey: RoomLightView.bodyKey) == nil)
    }

    // MARK: - Helpers

    /// Every view of `type` in `view`'s tree.
    private static func views<View: NSView>(
        _ type : View.Type,
        in view: NSView
    ) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// A loop of `status` with at least one body intent, the first such seed's.
    private static func loop(_ status: WorkerStatus) -> WorkerBehaviourLoop {
        let loops = (UInt64(1)...200).lazy.map { WorkerBehaviour(status).loop(seed: $0) }
        let hops  = loops.first { loop in
            loop.intents.contains { $0.keys.contains { $0.pose.hop > 0 } }
        }
        return (status == .waiting ? hops : nil) ?? loops.first { !$0.intents.isEmpty } ?? loops[loops.startIndex]
    }

    private static func room(_ status: WorkerStatus) -> RoomLightUniforms {
        RoomLightUniforms(
            status     : status,
            shape      : .circle,
            hasOccupant: true,
            camera     : .tilted
        )
    }

    /// Brows of `status` playing the loop of seed 1, in `window`'s content.
    private static func mascot(
        _ status : WorkerStatus,
        in window: NSWindow
    ) -> MascotLayer {
        let mascot = MascotLayer()
        mascot.frame  = CGRect(
            x     : 0,
            y     : 0,
            width : 56,
            height: 56
        )
        mascot.status = status
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(mascot)
        mascot.behave(seed: seed(for: status))
        return mascot
    }

    /// A seed whose loop in `status` has a body intent.
    private static func seed(for status: WorkerStatus) -> UInt64 {
        (UInt64(1)...200).first { !WorkerBehaviour(status).loop(seed: $0).intents.isEmpty } ?? 1
    }

    /// A borderless window that is never shown, so nothing reaches the screen or takes input.
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 400,
                height: 300
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    /// Pixels is a rendered room read back, in BGRA order, looked up in points.
    private struct Pixels {
        let width : Int
        let height: Int
        let size  : CGSize
        let bytes : [UInt8]

        func luma(_ x: Int, _ y: Int) -> Double {
            let column = min(width - 1, Int((Double(x) + 0.5) * Double(width) / size.width))
            let row    = min(height - 1, Int((Double(y) + 0.5) * Double(height) / size.height))
            let index  = (row * width + column) * 4
            return 0.2126 * Double(bytes[index + 2]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index])
        }
    }

    /// Renders `uniforms` into the renderer's ready bucket, or at one pixel per point, and reads it back.
    private static func render(
        _ uniforms   : RoomLightUniforms,
        with renderer: any RoomRenderer,
        device       : MTLDevice,
        size         : CGSize
    ) throws -> Pixels {
        let output     = (renderer as? RayTracedRoomRenderer)?.denoisedPixelSize ?? size
        let width      = Int(output.width)
        let height     = Int(output.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width      : width,
            height     : height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        let texture       = try #require(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(
            uniforms,
            size         : size,
            into         : texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        var bytes = [UInt8](
            repeating: 0,
            count    : width * height * 4
        )
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from       : MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return Pixels(
            width : width,
            height: height,
            size  : size,
            bytes : bytes
        )
    }
}
