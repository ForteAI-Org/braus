//
//  WebSelectPopup.swift
//  Braus
//

import CoreGraphics
import Foundation
import PerceptionCore

/// WebSelectPopup is the list of an open native `<select>`, drawn by Braus because Chrome draws
/// its own outside the page, where no scene or click reaches it.
///
/// `WebControls.pressControl` opens it; from then on the scene shows its options as menu items in
/// a pop-up section and the window listing shows a pop-up window, which is how the engine sees
/// any open menu. `pressMenuItem` chooses an option the way browser-use does: focus, set, `input`
/// and `change`, blur, then read the value back. Escape or a click outside closes it.
public struct WebSelectPopup: Sendable, Equatable {

    public struct Option: Sendable, Equatable {
        public var text      : String
        public var isSelected: Bool
        public var isEnabled : Bool

        public init(text: String, isSelected: Bool = false, isEnabled: Bool = true) {
            self.text       = text
            self.isSelected = isSelected
            self.isEnabled  = isEnabled
        }
    }

    /// What the select is called, as the scene names it.
    public var name   : String
    /// The select's box in the viewport.
    public var anchor : CGRect
    public var options: [Option]

    public init(name: String, anchor: CGRect, options: [Option]) {
        self.name    = name
        self.anchor  = anchor
        self.options = options
    }

    static let rowHeight   = 20.0
    static let minRowHeight = 2.0
    static let minWidth    = 120.0

    /// The section and container the options live in.
    public var sectionName: String { "pop-up (\(name))" }

    /// The options the viewport has room for, each at least `minRowHeight` tall.
    func shownOptions(in viewport: CGSize) -> [Option] {
        Array(options.prefix(max(1, Int(viewport.height / Self.minRowHeight))))
    }

    /// Where the list is drawn: under its select when it fits, else as low as it fits, never
    /// outside the viewport; rows shrink when there are more than fit at full height.
    public func frame(in viewport: CGSize) -> CGRect {
        let count  = Double(max(1, shownOptions(in: viewport).count))
        let row    = min(Self.rowHeight, max(Self.minRowHeight, viewport.height / count))
        let height = min(viewport.height, row * count)
        let width  = min(viewport.width, max(anchor.width, Self.minWidth))
        let x      = min(max(0, anchor.minX), viewport.width - width)
        let y      = anchor.maxY + height <= viewport.height ? anchor.maxY : max(0, viewport.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The options as menu items, normalized to the viewport.
    func elements(in viewport: CGSize) -> [SceneElement] {
        let frame = frame(in: viewport)
        let shown = shownOptions(in: viewport)
        let row   = frame.height / Double(max(1, shown.count))
        return shown.enumerated().map { index, option in
            let box    = CGRect(x: frame.minX, y: frame.minY + Double(index) * row, width: frame.width, height: row)
            let bounds = NormalizedRect(pixelBox: box, in: viewport)
            let label  = WebSceneBuilder.cut(WebSceneBuilder.clean(option.text))
            return SceneElement(
                id: SceneIdentity.key(kind: .control, label: label, bounds: bounds, isUnlabeled: label.isEmpty),
                kind: .control, label: label.isEmpty ? "empty option" : label, bounds: bounds, role: "AXMenuItem",
                state: option.isSelected ? .on : nil, isEnabled: option.isEnabled, container: sectionName,
                isUnlabeled: label.isEmpty, section: sectionName, labelOrigin: .title
            )
        }
    }
}
