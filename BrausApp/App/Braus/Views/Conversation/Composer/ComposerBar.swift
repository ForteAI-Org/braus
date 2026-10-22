//
//  ComposerBar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// ComposerBar is the conversation's composer (§13.1): a pill that floats over
/// the bottom of the transcript, holding the field and one circle pinned to its
/// bottom-trailing corner, Send, or Stop while a turn runs. While the recipient
/// holds the computer, a quiet Release the computer button comes out of the
/// circle toward the leading side; the circle itself never moves.
///
/// The bar is inset from the edges it is placed against and grows upward with
/// its text. The caller lays it over the transcript and gives the transcript
/// the bar's height as its bottom inset, so the last message scrolls clear of it.
///
/// The caller may put one accessory in the row, before the buttons: the
/// conversation puts the worker's model and effort there. It may also put
/// strips over the pill, such as the message a reply quotes; Escape in the
/// field can take it away (`onEscape(_:)`). A strip comes and goes with
/// `stripAnimation`, and the bar grows with it.
/// A composer that queues (`queuesWhileAnswering(_:)`) hands the draft to
/// `send` during a turn too, while the circle stays Stop. There is no Add
/// context or microphone: nothing supplies attachments or voice yet, and a
/// control that does nothing is not shown (§21.2). A recipient that cannot answer says so
/// only in the placeholder, with Send disabled; the draft stays editable, as
/// it does during a turn, where only sending waits for the turn to end.
///
/// The bar is a 52 point glass capsule in the conversation's centred column, with a `+` menu of the
/// caller's real items at its leading end and a light Send circle at its trailing end, its field
/// growing to eight lines; its strips sit above the pill, inset from its ends. `composerDock()`
/// sets it on the conversation's ground.
struct ComposerBar: View {

    /// The Send and Stop circle's side.
    nonisolated static let circleSide: CGFloat = 36

    /// The Release button's side.
    static let releaseSide: CGFloat = 30

    /// The room between the field, the accessory and the buttons.
    static let spacing: CGFloat = 10

    /// The lines the field shows before it scrolls.
    static let maximumLines = 8

    /// The release button's symbol: a door with an arrow out of it, leaving the seat.
    static let releaseSymbol = "rectangle.portrait.and.arrow.right"

    /// The pill's height around one line, and the height of the row its controls sit in.
    static let houseRowHeight: CGFloat = 52

    /// The room above and below the field, which centres one line in its row.
    static let houseFieldInset = (houseRowHeight - ComposerScrollView.oneLineHeight) / 2

    @Binding private var draft: String

    private let recipient  : String
    private let canAnswer  : Bool
    private let isAnswering: Bool
    private let send       : () -> Void
    private let stop       : () -> Void
    private let release    : (() -> Void)?

    /// What sits in the row before the buttons, set with `accessory(_:)`.
    private var accessoryView: AnyView?

    /// What sits joined above the pill, on its surface, set with `strip(_:)`.
    private var stripView: AnyView?

    /// What the `+` menu offers, set with `menu(_:)`; nil shows no `+`.
    private var menuView: AnyView?

    /// What Escape in the field does, set with `onEscape(_:)`; nil leaves it to the text view.
    private var escape: (() -> Void)?

    /// What answers the keys of a popup over the field, set with `popupKeys(_:)`.
    private var popupKeyHandler: ((ComposerTextView.PopupKey) -> Bool)?

    /// A count that puts the keyboard in the field each time it moves, set with `focusRequest(_:)`.
    private var focusRequest = 0

    /// Given the field's view, set with `fieldLink(_:)`.
    private var fieldLink: ComposerField.Link?

    /// Whether Return sends, or starts a new line with Command-Return sending; see `sendsOnReturn(_:)`.
    private var returnSends = true

    /// Whether sending during a turn hands the draft to `send` to queue; see `queuesWhileAnswering(_:)`.
    private var queues = false

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// - Parameters:
    ///   - recipient: the worker's name, in the placeholder and the labels.
    ///   - canAnswer: the recipient has a model that can answer; without one Send is disabled.
    ///   - isAnswering: a turn runs for the recipient, so the circle is Stop.
    ///   - release: gives the computer back; nil while the recipient does not hold it,
    ///     and the button is shown only while it is not nil.
    init(
        draft      : Binding<String>,
        recipient  : String,
        canAnswer  : Bool,
        isAnswering: Bool,
        send       : @escaping () -> Void,
        stop       : @escaping () -> Void,
        release    : (() -> Void)? = nil
    ) {
        _draft           = draft
        self.recipient   = recipient
        self.canAnswer   = canAnswer
        self.isAnswering = isAnswering
        self.send        = send
        self.stop        = stop
        self.release     = release
    }

    /// Something to say, someone to answer it, and no turn running for them.
    var canSend: Bool {
        canAnswer && !isAnswering && hasText
    }

    /// Something to say to someone answering now, in a composer that queues it.
    var canQueue: Bool {
        queues && canAnswer && isAnswering && hasText
    }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Message Milo", or what Milo needs before it can be messaged.
    var placeholder: String {
        canAnswer ? "Message \(recipient)" : "Choose a model before messaging \(recipient)."
    }

    /// The strips above a glass pill one line high at `houseRowHeight`, whose controls stay in a row
    /// of that height at its foot while the field grows above them.
    var body: some View {
        VStack(spacing: 0) {
            // The strips are tabs that inset themselves from the pill's ends (`ComposerTab`).
            stripView

            HStack(
                alignment: .bottom,
                spacing  : Self.spacing
            ) {
                if let menuView {
                    menuButton(menuView)
                        .frame(height: Self.houseRowHeight)
                }
                field
                    .padding(
                        .vertical,
                        Self.houseFieldInset
                    )
                Group {
                    accessoryView
                    actions
                }
                .frame(height: Self.houseRowHeight)
            }
            .padding(
                .leading,
                menuView == nil ? 20 : 10
            )
            .padding(
                .trailing,
                8
            )
            .modifier(GlassCapsule(cornerRadius: Self.houseRowHeight / 2))
            .shadow(
                color : .black.opacity(0.5),
                radius: 20,
                y     : 20
            )
        }
        .frame(maxWidth: RowGeometry.houseColumn)
        .padding(
            .horizontal,
            16
        )
        .padding(
            .bottom,
            20
        )
    }

    private var field: ComposerField {
        ComposerField(
            text        : $draft,
            placeholder : placeholder,
            onSubmit    : canSend || canQueue ? send : nil,
            returnSends : returnSends,
            onEscape    : escape,
            onPopupKey  : popupKeyHandler,
            focusRequest: focusRequest,
            maximumLines: Self.maximumLines,
            link        : fieldLink
        )
    }

    /// The `+`, a quiet circle that opens `content`.
    private func menuButton(_ content: AnyView) -> some View {
        Menu {
            content
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
        .help("More")
        .accessibilityLabel("More")
    }

    /// The bar with Return sending, or starting a new line with Command-Return sending.
    func sendsOnReturn(_ sends: Bool) -> ComposerBar {
        var bar = self
        bar.returnSends = sends
        return bar
    }

    /// The bar with `content` in its row, before the buttons.
    func accessory(@ViewBuilder _ content: () -> some View) -> ComposerBar {
        var bar = self
        bar.accessoryView = AnyView(content())
        return bar
    }

    /// The bar with `content` in the `+` menu, at the pill's leading end: the caller's real items
    /// only, and a caller with none sets no menu.
    func menu(@ViewBuilder _ content: () -> some View) -> ComposerBar {
        var bar = self
        bar.menuView = AnyView(content())
        return bar
    }

    /// The bar with `content` above the pill: strips stacked with no spacing,
    /// or nothing. The caller animates the change with `stripAnimation`.
    func strip(@ViewBuilder _ content: () -> some View) -> ComposerBar {
        var bar = self
        bar.stripView = AnyView(content())
        return bar
    }

    /// The bar that, while a turn runs, hands a draft to `send` on Return or
    /// Command-Return, to be queued, rather than doing nothing.
    func queuesWhileAnswering(_ queues: Bool) -> ComposerBar {
        var bar = self
        bar.queues = queues
        return bar
    }

    /// The timing of a strip's coming and going, a bubble's ease-out, which the
    /// pill's growth follows in the same animation, so nothing jumps.
    static let stripAnimation = Animation.easeOut(duration: 0.24)

    /// The bar with `action` run by Escape in the field; nil leaves Escape to the text view.
    func onEscape(_ action: (() -> Void)?) -> ComposerBar {
        var bar = self
        bar.escape = action
        return bar
    }

    /// The bar whose field offers ↑ ↓, Tab, Return and Escape to `handler`
    /// first, which answers whether a popup over the field took the key
    /// (`ComposerTextView.onPopupKey`). The keyboard never leaves the field.
    func popupKeys(_ handler: ((ComposerTextView.PopupKey) -> Bool)?) -> ComposerBar {
        var bar = self
        bar.popupKeyHandler = handler
        return bar
    }

    /// The bar that puts the keyboard in its field each time `request` moves.
    func focusRequest(_ request: Int) -> ComposerBar {
        var bar = self
        bar.focusRequest = request
        return bar
    }

    /// The bar that hands its field's view to `link`, for the conversation's flights to read.
    func fieldLink(_ link: ComposerField.Link?) -> ComposerBar {
        var bar = self
        bar.fieldLink = link
        return bar
    }

    /// Release, when shown, beside the circle: it comes out of the circle to the left and goes back
    /// into it.
    private var actions: some View {
        HStack(spacing: 6) {
            if let release {
                releaseButton(release)
                    .transition(.scale(scale: 0.3, anchor: .trailing).combined(with: .opacity))
            }
            circle
                .background { queueShortcut }
        }
        .animation(reducesMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: release != nil)
    }

    /// Command-Return while a draft can be queued. The circle is Stop then and
    /// answers Command-Period, so the shortcut that sends is on a button of its
    /// own, which draws nothing and takes no focus.
    @ViewBuilder
    private var queueShortcut: some View {
        if canQueue {
            Button(
                "Queue Message",
                action: send
            )
            .keyboardShortcut(
                .return,
                modifiers: .command
            )
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func releaseButton(_ release: @escaping () -> Void) -> some View {
        Button(action: release) {
            Image(systemName: Self.releaseSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.releaseSide, height: Self.releaseSide)
                // A quiet circle, as the `+` is.
                .background(
                    .white.opacity(0.06),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("End this worker’s computer session.")
        .accessibilityLabel("Release Computer")
    }

    /// Send, which becomes Stop in the same place while a turn runs, dimmed while nothing can be sent,
    /// with an animated change.
    private var circle: some View {
        let isEnabled = isAnswering || canSend
        return Button(action: isAnswering ? stop : send) {
            circleFace(isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .animation(reducesMotion ? nil : .easeInOut(duration: 0.2), value: isEnabled)
        .disabled(!isEnabled)
        .keyboardShortcut(isAnswering ? KeyboardShortcut(".", modifiers: .command)
                                      : KeyboardShortcut(.return, modifiers: .command))
        .help(isAnswering ? "Stop response." : "Send message.")
        .accessibilityLabel(isAnswering ? "Stop response from \(recipient)" : "Send Message")
    }

    /// The circle: light, with a dark glyph, and dimmed while nothing can be sent.
    private func circleFace(isEnabled: Bool) -> some View {
        Image(systemName: isAnswering ? "stop.fill" : "arrow.up")
            .font(.system(
                size  : isAnswering ? 13 : 15,
                weight: .semibold
            ))
            .foregroundStyle(.black)
            .frame(
                width : Self.circleSide,
                height: Self.circleSide
            )
            .background(
                LinearGradient(
                    colors    : [Color(white: 0.96), Color(white: 0.72)],
                    startPoint: UnitPoint(x: 0.33, y: 0),
                    endPoint  : UnitPoint(x: 0.67, y: 1)
                ),
                in: Circle()
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
    }
}

extension View {

    /// Sets the composer on its ground: in a column centred on the conversation's ground, solid behind
    /// it and fading to clear over `HouseFoot.fadeHeight` above it, so a message passing under
    /// dissolves with no edge. Applied outside the composer's popups, which rise from the bar itself.
    func composerDock() -> some View {
        padding(
            .horizontal,
            8
        )
        .padding(
            .top,
            HouseFoot.fadeHeight
        )
        .frame(maxWidth: .infinity)
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors    : [Color("HouseGround").opacity(0), Color("HouseGround")],
                    startPoint: .top,
                    endPoint  : .bottom
                )
                .frame(height: HouseFoot.fadeHeight)
                .allowsHitTesting(false)
                Color("HouseGround")
            }
        }
    }
}
