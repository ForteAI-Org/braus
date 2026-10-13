//
//  ScreenEnlargementTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import Foundation
import SeatBroker
import Testing
@testable import Braus

@MainActor
@Suite("The worker's screen enlarged over the conversation")
struct ScreenEnlargementTests {

    private let worker = UUID()

    @Test("The toolbar's toggle names the place the screen rests in")
    func theToggleNamesTheRestingPlace() {
        #expect(ScreenPlace.resting(showsInConversation: true) == .conversation)
        #expect(ScreenPlace.resting(showsInConversation: false) == .inspector)
    }

    @Test("Opened from the top right it returns there while the toggle is on, and to the inspector once it is off")
    func theOriginDoesNotDecideTheReturn() {
        let fromConversation = ScreenEnlargement(
            workerID: worker,
            origin  : .conversation
        )
        #expect(fromConversation.destination(showsInConversation: true) == .conversation)
        #expect(fromConversation.destination(showsInConversation: false) == .inspector)

        let fromInspector = ScreenEnlargement(
            workerID: worker,
            origin  : .inspector
        )
        // The inspector's card shows only while the toggle is off, so that is the usual return.
        #expect(fromInspector.destination(showsInConversation: false) == .inspector)
        #expect(fromInspector.destination(showsInConversation: true) == .conversation)
    }

    @Test("Closing marks the enlargement and keeps its worker and origin")
    func closingOnlyMarks() {
        var enlargement = ScreenEnlargement(
            workerID: worker,
            origin  : .inspector
        )
        #expect(!enlargement.isClosing)

        enlargement.close()
        #expect(enlargement.isClosing)
        #expect(enlargement.workerID == worker)
        #expect(enlargement.origin == .inspector)
    }

    @Test("A worker with no window to watch cannot enlarge it, and dismissing clears the state")
    func noWindowNoEnlargement() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        team.enlargeScreen(
            of  : worker,
            from: .conversation
        )
        #expect(team.enlargedScreen == nil)

        team.enlargedScreen = ScreenEnlargement(
            workerID: worker,
            origin  : .inspector
        )
        team.closeEnlargedScreen()
        #expect(team.enlargedScreen?.isClosing == true)

        team.dismissEnlargedScreen()
        #expect(team.enlargedScreen == nil)
    }
}
