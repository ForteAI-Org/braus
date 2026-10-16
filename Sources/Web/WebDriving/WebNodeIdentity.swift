//
//  WebNodeIdentity.swift
//  Braus
//

import Foundation

/// WebNodeIdentity is one DOM node of one document in one tab, as the web roles name a node a script
/// found and the engine then acts on: the tab's target and session, and the backend ids of the
/// document's own node and of the node. A node replaced in the same place, or the same page after a
/// navigation or a reload, is another identity, though the scene's element id, made of kind, label and
/// place, stays the same. Only this module reads it; everything else compares it whole.
public struct WebNodeIdentity: Sendable, Hashable {

    let targetID : String
    let sessionID: String
    /// The backend id of the document's own node.
    let document : Int
    /// The backend id of the node.
    let node     : Int
}
