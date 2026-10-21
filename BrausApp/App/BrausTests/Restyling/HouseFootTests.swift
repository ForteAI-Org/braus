//
//  HouseFootTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI
import Testing
@testable import Braus

@Suite("HouseFoot")
@MainActor
struct HouseFootTests {

    @Test("The account is a menu that holds Settings and Sign Out")
    func accountMenu() {
        #expect(HouseFoot.AccountButton.Action.allCases.map(\.title) == ["Settings…", "Sign Out"])
        #expect(String(reflecting: HouseFoot.AccountButton.Body.self).contains("SwiftUI.Menu<"))
        #expect(MockAccount.sample.monogram == "ER")
    }

    @Test("The archive is a button VoiceOver reads with its count")
    func archiveButton() {
        #expect(HouseFoot.ArchiveButton.spokenLabel(archivedCount: 3) == "Archive, 3 workers")
        #expect(String(reflecting: HouseFoot.ArchiveButton.Body.self).contains("SwiftUI.Button<"))
    }

    @Test("The foot keeps the account button when the archive is hidden")
    func accountWithoutArchive() {
        #expect(HouseFoot.items(archivedCount: 3) == [.account, .archive])
        #expect(HouseFoot.items(archivedCount: 0) == [.account])
    }
}
