//
//  SceneKnowledge.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// SceneKnowledge is what the living memory said about a scene when it annotated it, beside its
/// elements: whether what was learned applies to the window's state, and the operations learned on the
/// window itself rather than on one of its elements (a key or a shortcut, an insertion on the focus, a
/// scroll of the window, a menu command, a dialog's button by its title).
///
/// It is read with the scene and takes no part in its token: the elements, their states and the token an
/// action echoes are the live perception's, whatever the memory could or could not read. It names no
/// error and no value: a failed read is said as one, its detail stays in the process that met it.
public struct SceneKnowledge: Sendable, Equatable, Hashable, Codable {

    /// Status is what the memory could say about the scene's state.
    public enum Status: String, Sendable, Equatable, Hashable, Codable {
        /// The state is recognized and what was learned in it is shown, on its elements and below.
        case applied
        /// The state is recognized and nothing learned in it is offered yet.
        case nothing
        /// The state is not recognized: new, uncertain against a known one, or captured incompletely.
        case unrecognized
        /// The memory could not be read now: the scene is live, what was learned is not shown.
        case unavailable
    }

    public var status: Status
    /// The operations learned on the window itself, one line each, with their conditions.
    public var window: [String]

    public init(status: Status, window: [String] = []) {
        self.status = status
        self.window = window
    }

    /// The lines a model reads after the scene's header, only when the memory offers operations on
    /// the window itself. A status alone serves the memory and adds no line for the reader.
    public var lines: [String] {
        guard status == .applied, !window.isEmpty else { return [] }
        return ["memory: what was learned in this window's state is shown"] + window.map { "  window: \($0)" }
    }
}
