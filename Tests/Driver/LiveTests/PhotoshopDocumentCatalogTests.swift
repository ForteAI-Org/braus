//
//  PhotoshopDocumentCatalogTests.swift
//  AgentSeatKit
//

import Foundation
import Testing

@Suite("Scoped Photoshop document snapshots")
struct PhotoshopDocumentCatalogTests {

    @Test("a complete model snapshot identifies the active tab and the saved seed")
    func readsCompleteSnapshot() throws {
        let catalog = try PhotoshopDocumentCatalog(parsing: """
            BRAUS_DOCUMENTS\tfresh\t9\t2
            4\tProbe.png\t%2Fprivate%2Ftmp%2FProbe.png
            9\tUntitled%20%C3%A8\t
            BRAUS_DONE\tfresh
            """, token: "fresh")
        #expect(catalog.documents.count == 2)
        #expect(catalog.documents.first?.nativePath == "/private/tmp/Probe.png")
        #expect(catalog.documents.first?.url == URL(fileURLWithPath: "/private/tmp/Probe.png"))
        #expect(catalog.activeDocument?.name == "Untitled è")
    }

    @Test("stale, partial and contradictory snapshots cannot attest document ownership")
    func refusesInvalidSnapshots() {
        let invalid = [
            "BRAUS_DOCUMENTS\told\t4\t1\n4\tProbe.png\t%2Ftmp%2FProbe.png\nBRAUS_DONE\told",
            "BRAUS_DOCUMENTS\tfresh\t4\t1\n4\tProbe.png\t%2Ftmp%2FProbe.png",
            "BRAUS_DOCUMENTS\tfresh\t4\t2\n4\tProbe.png\t%2Ftmp%2FProbe.png\n4\tUntitled\t\nBRAUS_DONE\tfresh",
            "BRAUS_DOCUMENTS\tfresh\t8\t1\n4\tProbe.png\t%2Ftmp%2FProbe.png\nBRAUS_DONE\tfresh",
            "BRAUS_DOCUMENTS\tfresh\t4\t1\n4\tProbe.png\trelative.png\nBRAUS_DONE\tfresh",
            "BRAUS_DOCUMENTS\tfresh\tnone\t1\n4\tProbe.png\t%2Ftmp%2FProbe.png\nBRAUS_DONE\tfresh"
        ]
        for source in invalid {
            #expect(throws: PhotoshopDocumentCatalog.Failure.invalidSnapshot) {
                try PhotoshopDocumentCatalog(parsing: source, token: "fresh")
            }
        }
    }

    @Test("a creation action owns only one active unsaved addition to an unchanged seed")
    func limitsCreationOwnership() throws {
        let baseline = try PhotoshopDocumentCatalog(parsing: "BRAUS_DOCUMENTS\ta\t4\t1\n4\tProbe.png\t%2Ftmp%2FProbe.png\nBRAUS_DONE\ta", token: "a")
        func reading(active: Int, seed: String, created: String) throws -> PhotoshopDocumentCatalog {
            try PhotoshopDocumentCatalog(parsing: "BRAUS_DOCUMENTS\tb\t\(active)\t2\n4\tProbe.png\t\(seed)\n9\tUntitled\t\(created)\nBRAUS_DONE\tb", token: "b")
        }
        #expect(try reading(active: 9, seed: "%2Ftmp%2FProbe.png", created: "").createdDocument(since: baseline)?.id == 9)
        #expect(try reading(active: 4, seed: "%2Ftmp%2FProbe.png", created: "").createdDocument(since: baseline) == nil)
        #expect(try reading(active: 9, seed: "%2Ftmp%2FOther.png", created: "").createdDocument(since: baseline) == nil)
        #expect(try reading(active: 9, seed: "%2Ftmp%2FProbe.png", created: "%2Ftmp%2FUser.png").createdDocument(since: baseline) == nil)
    }
}
