//
//  RemoteContentQualification.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/10/2026.
//

/// RemoteContentQualification is what the seat accepts about another process's window drawn
/// inside a surface, which decides how far a Command may go into it (ADR 0014, ADR 0031).
nonisolated enum RemoteContentQualification: Sendable, Equatable {

    /// Nothing qualifies it: the Command is refused.
    case none

    /// The platform's Open and Save panel service, whose mouse and keyboard recipes were measured.
    case filePanelService

    /// An Apple extension drawn inside an Apple native application, as System Settings panes are.
    /// Its clicks and text go through accessibility only; nothing is posted into it.
    case appleExtension
}
