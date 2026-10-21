//
//  HouseComposer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseComposer is the mockup's composer: a glass pill holding, from leading to trailing, the `+`
/// menu, the message field, the model and effort menu, the context ring and Send.
///
/// The pill is 52 points high for one line. The field grows with its text up to `maximumLines`, then
/// scrolls inside; the pill keeps its ends' radius as it grows, and the controls stay in a 52 point
/// row at its foot, beside the field's last line. Whoever owns `text` animates the growth.
///
/// The field's focus belongs to the window, through `isFocused`, which moves it here when a worker
/// is chosen by pointer or Return pressed in the sidebar. Return sends a message that is not blank:
/// it hands `onSend` the text, the field's frame in `BubbleFlight.space`, where the text leaves
/// from, and how far the field had scrolled its lines, when known; it clears the field in the same
/// update. Shift-Return and Option-Return break the line.
/// The `+` menu's items and the ring's actions are placeholders.
struct HouseComposer: View {
    let worker: MockWorker

    @Binding var text: String

    let isFocused: FocusState<Bool>.Binding
    let onSend   : (_ text: String, _ field: CGRect, _ scroll: CGFloat?) -> Void

    /// The lines the field shows before it scrolls.
    static let maximumLines = 8

    /// The height of the pill around one line, and of the row the controls sit in.
    static let rowHeight: CGFloat = 52

    @State private var fieldFrame = CGRect.zero

    /// How far the field had scrolled its lines when Return was pressed, read before Return ends
    /// the editing, which takes the field's editor and its scroll away.
    @State private var scrollAtReturn: CGFloat?

    @State private var model = "Opus 5.5"

    @State private var effort = "High"

    @State private var showsChromeWindow = false

    @State private var showsContext = false

    var body: some View {
        HStack(
            alignment: .bottom,
            spacing  : 10
        ) {
            addMenu
                .frame(height: Self.rowHeight)
            field
            Group {
                modelMenu
                ConversationContextButton(
                    context        : Self.context,
                    worker         : worker.name,
                    isCompacting   : false,
                    waitReason     : nil,
                    compact        : {},
                    startFresh     : {},
                    isShowingDetail: $showsContext
                )
                .buttonStyle(.borderless)
                sendButton
            }
            .frame(height: Self.rowHeight)
        }
        .padding(
            .leading,
            10
        )
        .padding(
            .trailing,
            8
        )
        .modifier(GlassCapsule(cornerRadius: Self.rowHeight / 2))
        .shadow(
            color : .black.opacity(0.5),
            radius: 20,
            y     : 20
        )
    }

    /// The mock context: a third of a 200k window.
    private static let context = WorkerUsage.Context(
        tokens: 68_000,
        window: 200_000
    )

    private static let models  = ["Opus 5.5", "Haiku 4.5"]
    private static let efforts = ["Low", "Medium", "High"]

    /// The message field, its one line centred in the pill's first 52 points.
    private var field: some View {
        TextField(
            "Message \(worker.name)",
            text: $text,
            axis: .vertical
        )
        .lineLimit(1...Self.maximumLines)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused(isFocused)
        // Return in the field sends too; a second call from Send's shortcut finds the field empty.
        .onSubmit(send)
        .onKeyPress(
            .return,
            phases: .down
        ) { press in
            guard press.modifiers.contains(.shift) else {
                scrollAtReturn = Self.editorScroll()
                return .ignored
            }

            // Shift-Return breaks the line, as Option-Return does, through the field's editor.
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
            return .handled
        }
        .padding(
            .vertical,
            Self.fieldInset
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(BubbleFlight.space))
        } action: { frame in
            fieldFrame = frame.insetBy(
                dx: 0,
                dy: Self.fieldInset
            )
        }
    }

    /// The room above and below the field's lines: one line sits in the middle of the pill.
    private static let fieldInset: CGFloat = 17.5

    private var addMenu: some View {
        Menu {
            Button("Attach File…") {}
            Button("Search the Web") {}
            Toggle(
                "Show Chrome Window",
                isOn: $showsChromeWindow
            )
        } label: {
            Image(systemName: "plus")
                .font(.system(
                    size  : 15,
                    weight: .medium
                ))
                .foregroundStyle(.secondary)
                .frame(
                    width : 30,
                    height: 30
                )
                .background(
                    .white.opacity(0.06),
                    in: Circle()
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach a file, search the web, or show the Chrome window.")
        .accessibilityLabel("Add")
    }

    private var modelMenu: some View {
        Menu {
            Picker(
                "Model",
                selection: $model
            ) {
                ForEach(
                    Self.models,
                    id: \.self
                ) { Text($0) }
            }
            .pickerStyle(.inline)
            Picker(
                "Effort",
                selection: $effort
            ) {
                ForEach(
                    Self.efforts,
                    id: \.self
                ) { Text($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(model) · \(effort)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(
                    .horizontal,
                    10
                )
                .padding(
                    .vertical,
                    5
                )
                .background(
                    .white.opacity(0.06),
                    in: Capsule()
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the model and its effort.")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(
                    size  : 15,
                    weight: .semibold
                ))
                .foregroundStyle(.black)
                .frame(
                    width : 36,
                    height: 36
                )
                .background(
                    LinearGradient(
                        colors    : [Color(white: 0.96), Color(white: 0.72)],
                        startPoint: UnitPoint(x: 0.33, y: 0),
                        endPoint  : UnitPoint(x: 0.67, y: 1)
                    ),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return)
        .disabled(message.isEmpty)
        .help("Send")
        .accessibilityLabel("Send")
    }

    private var message: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !message.isEmpty else { return }

        // Send keeps the field editing, so its editor answers; Return has ended it.
        onSend(
            message,
            fieldFrame,
            Self.editorScroll() ?? scrollAtReturn
        )
        text           = ""
        scrollAtReturn = nil
    }

    /// How far the field editor has scrolled its lines up, when one is editing: the key window's,
    /// or, while the app is not active, the one a window keeps editing. The editor's clip view sits
    /// a little off the field, so the scroll is how far its bounds have moved past its frame.
    private static func editorScroll() -> CGFloat? {
        let windows = [NSApp.keyWindow].compactMap(\.self) + NSApp.windows
        let editors = windows.lazy.compactMap { $0.firstResponder as? NSTextView }
        guard let editor = editors.first(where: { $0.isFieldEditor && $0.window != nil }),
              let clip   = editor.superview as? NSClipView
        else { return nil }

        return clip.bounds.minY - clip.frame.minY
    }
}
