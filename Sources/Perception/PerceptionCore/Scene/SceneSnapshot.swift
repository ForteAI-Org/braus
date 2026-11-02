//
//  SceneSnapshot.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// SceneSnapshot is one window as text: the app, the window title, the composed element list, the
/// named panels, the known menu commands, and the token an action must echo.
///
/// It serializes to compact JSON and renders to a legible map (`SceneRendering`). It carries no
/// image; an actuator that needs a pixel derives it from an element's bounds and the viewport.
public struct SceneSnapshot: Sendable, Equatable, Hashable {

    public var bundleID: String
    public var appName: String
    public var windowTitle: String
    /// The captured viewport in pixels: what every `NormalizedRect` in this scene is relative to.
    public var viewportPixelSize: ViewportPixelSize
    public var elements: [SceneElement]
    /// Read-only native fields past the window edge, with no action targets.
    public var outOfViewFields: [OutOfViewField]
    /// Named window panels; empty when composition found no structure.
    public var sections: [SceneSection]
    /// Known menu paths, such as "File > Export...".
    public var commands: [String]
    public var token: SceneToken
    /// What the living memory said about the scene when it annotated it; nil for a scene it did not
    /// read. No part of the token.
    public var knowledge: SceneKnowledge?

    /// Builds a scene, computing the token from the content when none is supplied.
    public init(
        bundleID         : String,
        appName          : String,
        windowTitle      : String,
        viewportPixelSize: ViewportPixelSize,
        elements         : [SceneElement],
        outOfViewFields  : [OutOfViewField] = [],
        sections         : [SceneSection] = [],
        commands         : [String] = [],
        token            : SceneToken? = nil,
        knowledge        : SceneKnowledge? = nil
    ) {
        self.bundleID          = bundleID
        self.appName           = appName
        self.windowTitle       = windowTitle
        self.viewportPixelSize = viewportPixelSize
        self.elements          = elements
        self.outOfViewFields    = outOfViewFields
        self.sections          = sections
        self.commands          = commands
        self.token             = token ?? SceneToken(
            bundleID: bundleID, windowTitle: windowTitle, elements: elements, outOfViewFields: outOfViewFields
        )
        self.knowledge         = knowledge
    }

    /// The smallest section containing a normalized point, or nil when the point is in no panel.
    public func section(at point: CGPoint) -> SceneSection? {
        sections
            .filter { $0.bounds.contains(point) }
            .min { $0.bounds.area < $1.bounds.area }
    }

    /// The smallest element whose bounds contain a normalized point, or nil over no element.
    public func element(at point: CGPoint) -> SceneElement? {
        elements
            .filter { $0.bounds.contains(point) }
            .min { $0.bounds.area < $1.bounds.area }
    }
}

/// ViewportPixelSize is the pixel size of the captured window, the denominator of every normalized
/// rectangle in a scene. Encoded as the `[width, height]` array scenes have always carried.
public struct ViewportPixelSize: Sendable, Equatable, Hashable {

    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width  = width
        self.height = height
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

extension ViewportPixelSize: Codable {

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let width     = try container.decode(Int.self)
        let height    = try container.decode(Int.self)
        self.init(width: width, height: height)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(width)
        try container.encode(height)
    }
}

extension SceneSnapshot: Codable {

    private enum CodingKeys: String, CodingKey {
        case bundleID, windowTitle, elements, outOfViewFields, sections, commands, token
        case knowledge         = "memory"
        case appName           = "app"
        case viewportPixelSize = "viewportPx"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleID: try values.decode(String.self, forKey: .bundleID),
            appName: try values.decode(String.self, forKey: .appName),
            windowTitle: try values.decode(String.self, forKey: .windowTitle),
            viewportPixelSize: try values.decode(ViewportPixelSize.self, forKey: .viewportPixelSize),
            elements: try values.decode([SceneElement].self, forKey: .elements),
            outOfViewFields: try values.decodeIfPresent([OutOfViewField].self, forKey: .outOfViewFields) ?? [],
            sections: try values.decode([SceneSection].self, forKey: .sections),
            commands: try values.decode([String].self, forKey: .commands),
            token: try values.decode(SceneToken.self, forKey: .token),
            knowledge: try values.decodeIfPresent(SceneKnowledge.self, forKey: .knowledge)
        )
    }
}
