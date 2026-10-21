//
//  HouseComposer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import ModelTransports
import SwiftUI

/// HouseComposer is the mockup's composer: a glass pill holding, from leading to trailing, the `+`
/// menu, the message field, the app's model and effort button (`ConversationModelButton`) and Send.
///
/// The pill is 52 points high for one line. The field (`HouseComposerField`) grows with its text up to
/// eight lines, then scrolls inside; the pill keeps its ends' radius as it grows, and the controls
/// stay in a 52 point row at its foot, beside the field's last line. Whoever owns `text` animates
/// the growth, from the field's width (`onFieldWidth`) and `HouseComposerField.height(of:width:)`.
///
/// The field's focus belongs to the window, through `isFocused`, which moves it here when a worker
/// is chosen by pointer or Return pressed in the sidebar. Return or Send sends a message that is not
/// blank: it hands `onSend` the text, the frame its lines start in, in `BubbleFlight.space`, and how
/// far the field had scrolled them, when known; it clears the field in the same update. While
/// `isDeparting`, the field shows no placeholder. Shift-Return and Option-Return break the line.
/// The model button opens the app's model popup above the pill, on `MockTeam`'s values; the `+`
/// menu's Attach File and Search the Web are placeholders.
struct HouseComposer: View {
    let worker: MockWorker

    @Binding var text: String

    let isFocused   : FocusState<Bool>.Binding

    /// Whether a sent text is still leaving the field, which shows no placeholder meanwhile.
    let isDeparting : Bool

    let onFieldWidth: (CGFloat) -> Void
    let onSend      : (_ text: String, _ field: CGRect, _ scroll: CGFloat?) -> Void

    /// The height of the pill around one line, and of the row the controls sit in.
    static let rowHeight: CGFloat = 52

    @State private var fieldFrame = CGRect.zero

    @State private var link = HouseComposerField.Link()

    @Environment(MockTeam.self)
    private var team: MockTeam?

    @State private var isChoosingModel = false

    /// The model button's frame in the window, which the popup is centred on.
    @State private var modelButtonFrame = CGRect.zero

    var body: some View {
        HStack(
            alignment: .bottom,
            spacing  : 10
        ) {
            addMenu
                .frame(height: Self.rowHeight)
            field
            Group {
                modelButton
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
        .modelPopup(
            isPresented: $isChoosingModel,
            button     : modelButtonFrame,
            selection  : selection,
            catalogue  : team.map { $0.catalogue(for: selection.wrappedValue.provider) },
            unavailable: nil,
            onClose    : {}
        )
    }

    /// The message field, its one line centred in the pill's first 52 points.
    private var field: some View {
        HouseComposerField(
            text            : $text,
            placeholder     : "Message \(worker.name)",
            isFocused       : isFocused,
            hidesPlaceholder: isDeparting,
            link            : link
        ) { scroll in
            send(scrolled: scroll)
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
            onFieldWidth(fieldFrame.width)
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
                isOn: Binding(
                    get: { team?.showsBrowserWindow(of: worker) ?? false },
                    set: { shows in
                        team?.setShowsBrowserWindow(
                            shows,
                            of: worker
                        )
                    }
                )
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

    /// The worker's model and effort, its highlight 24 points high as the house's own pill was;
    /// nothing outside the house window, which supplies the team.
    @ViewBuilder
    private var modelButton: some View {
        if let team {
            ConversationModelButton(
                selection: selection.wrappedValue,
                catalogue: team.catalogue(for: selection.wrappedValue.provider),
                isOpen   : $isChoosingModel,
                frame    : $modelButtonFrame,
                isEnabled: !team.isAnswering(worker),
                height   : 24
            )
            .fixedSize()
        }
    }

    /// The worker's selection, which the popup changes at once.
    private var selection: Binding<ModelSelection> {
        Binding(
            get: { team?.selection(of: worker) ?? .default },
            set: { selection in
                team?.select(
                    selection,
                    for: worker
                )
            }
        )
    }

    private var sendButton: some View {
        Button {
            send(scrolled: nil)
        } label: {
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

    /// Sends the message, from Return with the scroll the field read, or from Send, which leaves
    /// the field editing, so its editor still knows how far it has scrolled.
    private func send(scrolled scroll: CGFloat?) {
        guard !message.isEmpty else { return }

        onSend(
            message,
            fieldFrame,
            scroll ?? link.scroll()
        )
        text = ""
    }
}
