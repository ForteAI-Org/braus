//
//  BrainGraphView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainGraphView is one application's Brain as a graph that moves. A node
/// dragged pulls what it is joined to along and the graph settles when it is
/// let go; a drag on empty space pans, a pinch zooms about the pointer, and the
/// buttons in the corner zoom for a mouse and frame the whole graph again. A
/// control's name shows under the pointer. When the Brain grew over time, the
/// timeline under the graph shows it as it stood at any moment, and Play grows
/// it again from its first node.
struct BrainGraphView: View {

    let simulation: BrainSimulation

    /// How far along the graph's span the timeline stands, 0 at its first node and 1 now.
    @State private var progress = 1.0

    @State private var isPlaying = false

    /// Nil until the graph is moved, when the view frames the settled graph whatever its size.
    @State private var camera : BrainCamera?
    @State private var automaticBounds: CGRect?
    @State private var pinched: BrainCamera?
    @State private var size   = CGSize.zero
    @State private var selected: Int?
    @State private var hovered: Int?
    @State private var drag   : Drag?

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// What a drag started on: a node, held that far from the pointer, or empty space.
    private enum Drag {
        case node(offset: CGVector)
        case pan(from: BrainCamera)
    }

    var body: some View {
        VStack(spacing: 0) {
            legend
            drawing
        }
    }

    private var drawing: some View {
        BrainCanvas(
            simulation: simulation,
            camera    : shownCamera,
            hovered   : selected ?? hovered
        )
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { point in selected = node(at: point) }
        .gesture(dragging)
        .simultaneousGesture(pinching)
        .onContinuousHover { phase in
            guard drag == nil else { return }

            if case .active(let point) = phase { hovered = node(at: point) } else { hovered = nil }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Brain Graph"))
        .accessibilityValue(String(localized: "\(simulation.physics.isPresent.count { $0 }) nodes"))
        .accessibilityChildren {
            ForEach(simulation.graph.nodes.indices, id: \.self) { index in
                if simulation.physics.isPresent[index] {
                    Button(simulation.graph.nodes[index].label) { selected = index }
                        .accessibilityHint(simulation.graph.nodes[index].detail ?? "")
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let selected, simulation.physics.isPresent[selected] {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(simulation.graph.nodes[selected].label).font(.headline)
                        Spacer()
                        Button { self.selected = nil } label: {
                            Label(String(localized: "Close details"), systemImage: "xmark")
                        }.labelStyle(.iconOnly)
                    }
                    if let detail = simulation.graph.nodes[selected].detail {
                        ScrollView { Text(detail).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 180)
                    }
                }
                .font(.caption).padding(12).frame(width: 270)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12).padding(.bottom, 85)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            BrainZoomControls(
                zoomIn : { zoom(by: 1.5) },
                zoomOut: { zoom(by: 1 / 1.5) },
                fit    : fit
            )
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if grows {
                BrainTimeline(
                    progress : $progress,
                    isPlaying: $isPlaying,
                    moment   : moment
                )
                .padding(
                    .bottom,
                    16
                )
            }
        }
        .task(id: isPlaying) { await play() }
        .onAppear {
            simulation.reveal(upTo: moment)
            simulation.beginEntrance()
            updateAutomaticFit()
        }
        .onChange(of: progress) {
            simulation.reveal(upTo: moment)
            if let selected, !simulation.physics.isPresent[selected] { self.selected = nil }
            if let hovered, !simulation.physics.isPresent[hovered] { self.hovered = nil }
            if !isPlaying { updateAutomaticFit() }
        }
        .onChange(of: simulation.isAwake) {
            if !simulation.isAwake { updateAutomaticFit() }
        }
        .onChange(of: isPlaying) {
            if !isPlaying { updateAutomaticFit() }
        }
        .onChange(
            of     : reducesMotion,
            initial: true
        ) {
            simulation.animates = !reducesMotion
        }
    }

    /// The explanation occupies layout space so it never hides nodes on a narrow window.
    private var legend: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(simulation.graph.isInspection
                     ? String(localized: "Saved observations") : String(localized: "Historical naming projection"))
                    .font(.headline)
                Text(String(localized: "Follow the arrows from a screen through an action to the observed result. Select a node for details."))
                if simulation.graph.isInspection {
                    Text(String(localized: "Actions: orange = awaiting confirmation · green = available for reuse · red = limited reuse"))
                    Text(String(localized: "Playback shows when observations were first saved. It does not replay actions or their later checks."))
                }
            }
            .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
    }

    // MARK: Time

    /// The moment the timeline stands at.
    private var moment: Date {
        let span = simulation.graph.span
        return span.lowerBound.addingTimeInterval(span.upperBound.timeIntervalSince(span.lowerBound) * progress)
    }

    /// A Brain learned in one look has no growth to play.
    private var grows: Bool { simulation.graph.span.lowerBound < simulation.graph.span.upperBound }

    /// Moves the timeline from where it stands to now, in about six seconds.
    private func play() async {
        guard isPlaying else { return }

        while isPlaying, progress < 1 {
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            progress = min(1, progress + 0.005)
        }
        isPlaying = false
    }

    // MARK: Camera

    private var shownCamera: BrainCamera {
        camera ?? BrainCamera(
            fitting: automaticBounds ?? simulation.restingBounds,
            in     : size
        )
    }

    private func updateAutomaticFit() {
        guard camera == nil else { return }
        automaticBounds = simulation.physics.presentBounds
    }

    private var motion: Animation? { reducesMotion ? nil : .smooth(duration: 0.35) }

    private func zoom(by factor: CGFloat) {
        withAnimation(motion) {
            camera = shownCamera.zoomed(
                by   : factor,
                about: CGPoint(
                    x: size.width / 2,
                    y: size.height / 2
                ),
                in   : size
            )
        }
    }

    private func fit() {
        withAnimation(motion) {
            camera = BrainCamera(
                fitting: simulation.physics.presentBounds,
                in     : size
            )
        }
    }

    /// The shown node under `point`, within a few points of its edge.
    private func node(at point: CGPoint) -> Int? {
        let camera  = shownCamera
        let physics = simulation.physics
        return physics.positions.indices
            .filter { physics.isPresent[$0] }
            .map { index in
                let centre = camera.screen(
                    physics.positions[index],
                    in: size
                )
                return (index, hypot(centre.x - point.x, centre.y - point.y))
            }
            .filter { $0.1 <= camera.radius(simulation.graph.nodes[$0.0].radius) + 4 }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: Gestures

    /// A drag that starts on a node carries the node; one that starts on empty space pans.
    private var dragging: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let camera = shownCamera
                if drag == nil {
                    self.camera = camera
                    if let node = node(at: value.startLocation) {
                        let grabbed = camera.graph(
                            value.startLocation,
                            in: size
                        )
                        let held    = simulation.physics.positions[node]
                        drag        = .node(offset: CGVector(
                            dx: held.x - grabbed.x,
                            dy: held.y - grabbed.y
                        ))
                        hovered     = node
                        simulation.hold(node)
                    } else {
                        drag = .pan(from: camera)
                    }
                }

                switch drag {
                case .node(let offset):
                    let point = camera.graph(
                        value.location,
                        in: size
                    )
                    simulation.move(to: CGPoint(
                        x: point.x + offset.dx,
                        y: point.y + offset.dy
                    ))
                case .pan(let start):
                    self.camera = start.panned(by: value.translation)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .node = drag { simulation.release() }
                drag = nil
            }
    }

    private var pinching: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinched ?? shownCamera
                pinched   = start
                camera    = start.zoomed(
                    by   : value.magnification,
                    about: value.startLocation,
                    in   : size
                )
            }
            .onEnded { _ in pinched = nil }
    }
}
