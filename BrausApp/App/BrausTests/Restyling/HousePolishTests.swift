//
//  HousePolishTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import ApplicationServices
import ModelTransports
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

/// HousePolishTests covers the small corrections to the restyled window: Edit Worker…'s request, the
/// names VoiceOver reads on the worker fields and the ground of the failure screen.
@MainActor
@Suite("The restyled window's polish")
struct HousePolishTests {

    @Test("Edit Worker… chooses the worker and asks for its name, and the request is the model's to clear")
    func editWorkerAsksForTheName() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store  = try WorkspaceStore.opening(in: directory)
        let first  = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        )
        let second = try await store.createWorker(
            name      : "Nova",
            appearance: TemporaryStore.appearance()
        )
        let team = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.load()
        team.selection = first.id
        #expect(team.editingWorker == nil)

        team.editWorker(second.id)
        #expect(team.selection == second.id)
        #expect(team.editingWorker == second.id)
    }

    @Test(
        "The New Worker sheet's fields and the Worker section's fields carry their own names",
        .enabled(
            if     : AXIsProcessTrusted(),
            "reads the window as an assistive client does, which needs the Accessibility permission"
        )
    )
    func fieldsAreNamed() async throws {
        let sheet = NSHostingView(rootView: HouseNewWorkerSheet(
            shapes     : HouseFixture.workers.map(\.shape),
            connections: { [.claudeCode: .ready] },
            catalogue  : { _ in [ModelInfo(id: "model-a", efforts: [.low])] }
        ) { _ in })
        let section = NSHostingView(rootView: Form {
            HouseWorkerSection(
                name         : "Atlas",
                role         : "Engineer",
                shape        : .lens,
                commitName   : { _ in },
                commitRole   : { _ in },
                commitShape  : { _ in },
                takesKeyboard: false,
                tookKeyboard : {}
            )
        }
        .formStyle(.grouped))

        for (host, names) in [
            (sheet   as NSView, ["Name", "Role", "Instructions", "Provider", "Model"]),
            (section as NSView, ["Name", "Role", "Shape"]),
        ] {
            let window = NSWindow(
                contentRect: CGRect(
                    x     : -30_000,
                    y     : 0,
                    width : 460,
                    height: 570
                ),
                styleMask  : [.titled],
                backing    : .buffered,
                defer      : false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.title       = "HousePolishTests-\(UUID().uuidString)"
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .seconds(1))

            let app    = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let target = try #require(Self.children(of: app).first { Self.text(of: $0, "AXTitle") == window.title })
            var labels = Set<String>()
            func walk(_ element: AXUIElement, _ depth: Int) {
                guard depth < 30 else { return }

                let role  = Self.text(of: element, "AXRole") ?? "-"
                let label = Self.text(of: element, "AXDescription") ?? Self.text(of: element, "AXTitle") ?? ""
                if ["AXTextField", "AXTextArea", "AXPopUpButton", "AXButton"].contains(role), !label.isEmpty {
                    labels.insert(label)
                }
                for child in Self.children(of: element) { walk(child, depth + 1) }
            }
            walk(target, 0)
            for name in names {
                #expect(labels.contains(name), "no control is named \(name) among \(labels.sorted())")
            }
        }
    }

    /// An accessibility attribute's string, nil when it has none.
    private static func text(
        of element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }

        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success else { return [] }

        return value as? [AXUIElement] ?? []
    }

    @Test("The failure screen stands on the house's ground, not the system's grey")
    func failureScreenGround() throws {
        let renderer = ImageRenderer(content: WorkspaceFailureView(failure: "disk full")
            .frame(
                width : 300,
                height: 200
            )
            .environment(
                \.colorScheme,
                .dark
            ))
        renderer.scale = 1
        let image  = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let corner = try #require(bitmap.colorAt(
            x: 2,
            y: 2
        )?.usingColorSpace(.deviceRGB))

        let ground = try #require(NSColor(named: "RestylingGround")?.usingColorSpace(.deviceRGB))
        #expect(corner.alphaComponent == 1)
        #expect(abs(corner.redComponent - ground.redComponent) < 0.02)
        #expect(abs(corner.greenComponent - ground.greenComponent) < 0.02)
        #expect(abs(corner.blueComponent - ground.blueComponent) < 0.02)
    }
}
