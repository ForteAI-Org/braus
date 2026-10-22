//
//  HouseWorkerSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import SwiftUI

/// HouseWorkerSection is the worker as the person made it: its name, its role and its shape, which
/// opens the New Worker sheet's shape grid in a popover. A new shape re-renders the worker's room
/// and its mascot at the top of the conversation.
///
/// The section holds what is being typed and hands finished values to its closures, which the
/// inspector (`HouseLiveInspector`) saves. The name and the role are taken on Return, when the field
/// loses the keyboard or when the section goes away, and a name emptied there comes back: a worker
/// always has one. Its rows are a little taller than the system's (`InspectorRowSpacing`), with the
/// house's gap after the section. While `takesKeyboard` is true, the Name field takes the keyboard
/// and `tookKeyboard` is called, which is how Edit Worker… lands the person in it.
struct HouseWorkerSection: View {

    /// The values as stored; a change from outside replaces what is shown.
    let name : String
    let role : String
    let shape: WorkerShape

    /// Receives a trimmed, non-empty name.
    let commitName : (String) -> Void
    let commitRole : (String) -> Void
    let commitShape: (WorkerShape) -> Void

    /// True while the person has asked to edit this worker's name.
    let takesKeyboard: Bool

    /// Called once the Name field has the keyboard.
    let tookKeyboard: () -> Void

    @State private var shownName : String
    @State private var shownRole : String
    @State private var shownShape: WorkerShape

    @State private var isChoosingShape = false

    @FocusState private var isNameFocused: Bool

    @FocusState private var isRoleFocused: Bool

    init(
        name         : String,
        role         : String,
        shape        : WorkerShape,
        commitName   : @escaping (String) -> Void,
        commitRole   : @escaping (String) -> Void,
        commitShape  : @escaping (WorkerShape) -> Void,
        takesKeyboard: Bool = false,
        tookKeyboard : @escaping () -> Void = {}
    ) {
        self.name          = name
        self.role          = role
        self.shape         = shape
        self.commitName    = commitName
        self.commitRole    = commitRole
        self.commitShape   = commitShape
        self.takesKeyboard = takesKeyboard
        self.tookKeyboard  = tookKeyboard
        _shownName  = State(initialValue: name)
        _shownRole  = State(initialValue: role)
        _shownShape = State(initialValue: shape)
    }

    var body: some View {
        Section {
            TextField(
                "Name",
                text  : $shownName,
                prompt: Text("Worker name")
            )
            .padding(.vertical, rowPadding)
            .focused($isNameFocused)
            .onSubmit(takeName)
            .accessibilityLabel("Name")

            TextField(
                "Role",
                text  : $shownRole,
                prompt: Text("Example: Researcher")
            )
            .padding(.vertical, rowPadding)
            .focused($isRoleFocused)
            .onSubmit(takeRole)
            .accessibilityLabel("Role")

            Button { isChoosingShape = true } label: {
                LabeledContent("Shape") {
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing  : 6
                    ) {
                        // The mascot is an overlay, so only the text sets the row's baseline and
                        // the shape's name lines up with the label.
                        Text(shownShape.name)
                            .padding(.leading, 34)
                            .overlay(alignment: .leading) {
                                HouseWorkerPortrait(
                                    shape : shownShape,
                                    status: .free,
                                    size  : 18,
                                    brows : .idle
                                )
                                .frame(
                                    width : 28,
                                    height: 18
                                )
                            }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, rowPadding)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shape")
            .accessibilityValue(shownShape.name)
            .accessibilityHint("Shows the shapes to choose from")
            .accessibilityAddTraits(.isButton)
            .popover(
                isPresented: $isChoosingShape,
                arrowEdge  : .leading
            ) {
                HouseShapeGrid(selection: $shownShape)
                    .padding(12)
            }
        } header: {
            Text("Worker")
        } footer: {
            HouseSectionGap()
        }
        .task(id: takesKeyboard) {
            guard takesKeyboard else { return }

            // Asked for before the inspector is in its window, the focus is dropped and reads false again.
            for _ in 0..<10 {
                await Task.yield()
                isNameFocused = true
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                if isNameFocused { break }
            }
            tookKeyboard()
        }
        .onChange(of: isNameFocused) {
            if !isNameFocused { takeName() }
        }
        .onChange(of: isRoleFocused) {
            if !isRoleFocused { takeRole() }
        }
        .onChange(of: shownShape) {
            if shownShape != shape { commitShape(shownShape) }
        }
        .onChange(of: name) { shownName = name }
        .onChange(of: role) { shownRole = role }
        .onChange(of: shape) { shownShape = shape }
        // A worker chosen while a field still has the keyboard takes what was typed.
        .onDisappear {
            takeName()
            takeRole()
        }
    }

    private var rowPadding: CGFloat { InspectorRowSpacing.vertical }

    private func takeName() {
        let taken = Self.takingName(
            shownName,
            stored: name
        )
        shownName = taken.shown
        if let value = taken.commit { commitName(value) }
    }

    private func takeRole() {
        let taken = Self.takingRole(
            shownRole,
            stored: role
        )
        shownRole = taken.shown
        if let value = taken.commit { commitRole(value) }
    }

    /// What a name typed in the field comes to: trimmed, and the stored one back when it is blank. The
    /// value to commit is nil when nothing changed.
    static func takingName(
        _ typed: String,
        stored : String
    ) -> (shown: String, commit: String?) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (stored, nil) }

        return (trimmed, trimmed == stored ? nil : trimmed)
    }

    /// What a role typed in the field comes to: trimmed, and blank is a role cleared, which is allowed.
    static func takingRole(
        _ typed: String,
        stored : String
    ) -> (shown: String, commit: String?) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, trimmed == stored ? nil : trimmed)
    }
}
