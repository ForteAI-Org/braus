//
//  WindowListing.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// WindowListing supplies the on-screen windows one process owns, front to back, as the window
/// server orders them. It is a read of the current moment; a second call may answer differently.
/// `async` because a conformer may ask the app itself (the MacDriver's accessibility listing), which
/// must not run on the caller's actor (MacDriver spec section 3, rule 3).
public protocol WindowListing: Sendable {

    func windows(ownedBy processID: pid_t) async throws -> [WindowRow]
}
