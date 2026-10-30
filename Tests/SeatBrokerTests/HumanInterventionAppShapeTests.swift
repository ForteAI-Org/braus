//
//  HumanInterventionAppShapeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore
import Testing
@testable import SeatBroker

/// Captions are hints, never required: the vocabulary reads whole captions in several languages and refines a fact
/// type only; no fact depends on it.
@Suite
struct HumanInterventionAppShapeTests {
    @Test func vocabularyReadsWholeCaptionsInSeveralLanguages() {
        typealias Vocabulary = HumanInterventionVocabulary
        #expect(Vocabulary.meaning(of: "Move to Trash") == .delete)
        #expect(Vocabulary.meaning(of: "Elimina") == .delete)
        #expect(Vocabulary.meaning(of: "Cancella") == .delete)
        #expect(Vocabulary.meaning(of: "Annulla") == .cancel)
        #expect(Vocabulary.meaning(of: "Löschen") == .delete)
        #expect(Vocabulary.meaning(of: "Schließen") == .close)
        #expect(Vocabulary.meaning(of: "OK") == .commit)
        #expect(Vocabulary.meaning(of: "Nuova traccia…", leadingWord: true) == .create)
        // A leading word counts only where asked: a slot named after a verb is not that command.
        #expect(Vocabulary.meaning(of: "Insert Assignment A") == nil)
        #expect(Vocabulary.meaning(of: nil) == nil)
    }
}
