//
//  SceneTextLayout.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import Foundation

/// SceneTextLayout is the scene text `SceneSnapshot.text()` writes, kept in its parts so a reader
/// with a size limit can take whole sections of it rather than a cut.
///
/// `text` is the parts joined in the order `text()` writes them: `head`, the sections in reading
/// order and the unsectioned elements, `commands`, then the fields past the window's edge.
public struct SceneTextLayout: Sendable, Equatable {

    /// The header line and the memory's lines about the scene.
    public let head: String

    /// The sections and the unsectioned elements, in the text's order.
    public let sections: [SceneTextPart]

    /// The line of known menu paths, or empty.
    public let commands: String

    /// The fields past the window's edge, when the scene has any.
    public let edge: SceneTextPart?

    /// Every part a reader can ask for by its title, in the text's order.
    public var parts: [SceneTextPart] { sections + (edge.map { [$0] } ?? []) }

    /// The whole scene text, byte for byte what `SceneSnapshot.text()` returns.
    public var text: String {
        head + sections.map(\.text).joined() + commands + (edge?.text ?? "")
    }
}

/// SceneTextPart is one section of the scene text: its `##` heading line and its element lines.
public struct SceneTextPart: Sendable, Equatable {

    /// The name the heading prints, which `resolveSection(named:)` matches.
    public let title: String

    /// The `## title @x,y wxh` line with its newline; empty for a scene without sections, whose
    /// elements are written with no heading.
    public let heading: String

    /// The element lines under the heading, each ending in a newline.
    public let body: String

    /// The elements, or fields past the window's edge, the part holds.
    public let elementCount: Int

    public var text: String { heading + body }
}
