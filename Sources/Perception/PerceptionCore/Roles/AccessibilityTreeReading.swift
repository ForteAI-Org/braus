//
//  AccessibilityTreeReading.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// AccessibilityTreeReading reads the facts of one accessibility tree, node by node, so the walk that
/// turns the tree into scene elements is generic: the live conformer wraps the system's element
/// handles, a test supplies plain objects, and the algorithm never learns which.
///
/// Every read is a question about the current moment; a node may vanish between two reads, and a
/// conformer answers nil rather than inventing a value. Frames are in global top-left points and
/// may be stale after a window moved, which is why the core judges them (`AccessibilityFrameTrust`).
public protocol AccessibilityTreeReading: Sendable {

    associatedtype Node

    func role(_ node: Node) -> String?
    func subrole(_ node: Node) -> String?
    func title(_ node: Node) -> String?
    func descriptionText(_ node: Node) -> String?
    func identifier(_ node: Node) -> String?
    /// The exact text value, including button values. Empty is a successful read; nil is unavailable.
    func value(_ node: Node) -> String?
    /// The node's own selection in UTF-16 units; nil when the provider cannot read it.
    func selectedRange(_ node: Node) -> NSRange?
    /// Whether the node owns keyboard focus within its application; nil when unreadable.
    /// This does not establish that its application is in the foreground.
    func isFocused(_ node: Node) -> Bool?
    /// The value as a number, for checkboxes and radios: 0 off, 1 on, 2 mixed.
    func numericValue(_ node: Node) -> Int?
    /// The node's own `AXSelected`, for a segmented button; nil when it does not answer.
    func isSelected(_ node: Node) -> Bool?
    /// Reads a button's state using its exact text value, including an empty string.
    /// Nil means unknown. The default recognizes only a positive native selection.
    func buttonState(_ node: Node, value: String?) -> ControlState?
    func isEnabled(_ node: Node) -> Bool?
    func actions(_ node: Node) -> [String]
    func frame(_ node: Node) -> CGRect?
    func children(_ node: Node) -> [Node]
}

extension AccessibilityTreeReading {
    public func selectedRange(_ node: Node) -> NSRange? { nil }
    public func isFocused(_ node: Node) -> Bool? { nil }
    public func isSelected(_ node: Node) -> Bool? { nil }
    public func buttonState(_ node: Node, value: String?) -> ControlState? {
        isSelected(node) == true ? .on : nil
    }
}
