//
//  HouseFoot.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseFoot is the sidebar's foot: the account's monogram, a menu that holds Settings and Sign Out,
/// and the archive's door to its right, left out when there is no archive.
///
/// It floats over the rooms, which scroll under it to the window's edge. It has no box of its own:
/// its ground is the sidebar's colour, solid behind the controls and fading to clear over
/// `fadeHeight` above them, so a room passing under dissolves with no edge. The fade lets clicks
/// through to the rooms. Its height, fade included, is the inset the rooms scroll clear of.
struct HouseFoot: View {
    let account      : MockAccount
    let archivedCount: Int
    let isCompact    : Bool

    /// The height over which the foot's ground fades to clear, above its controls.
    static let fadeHeight: CGFloat = 32

    /// The side of the account's round button.
    static let accountSide: CGFloat = 28

    var body: some View {
        controls
            .frame(
                maxWidth : .infinity,
                alignment: isCompact && archivedCount > 0 ? .center : .leading
            )
            .padding(
                .horizontal,
                HouseLayout.margin
            )
            .padding(
                .bottom,
                HouseLayout.margin
            )
            .padding(
                .top,
                Self.fadeHeight
            )
            .background { ground }
    }

    /// Item is one of the foot's controls.
    enum Item: Hashable {
        case account
        case archive
    }

    /// The foot's controls, leading first: the account always, the archive only when it holds a worker.
    static func items(archivedCount: Int) -> [Item] {
        archivedCount > 0 ? [.account, .archive] : [.account]
    }

    @ViewBuilder private var controls: some View {
        if isCompact && archivedCount > 0 {
            // The monogram and the door side by side, or one over the other where they cannot fit.
            ViewThatFits {
                HStack(spacing: 8) { row }
                VStack(spacing: 6) { row }
            }
        } else {
            HStack(spacing: 8) { row }
        }
    }

    private var row: some View {
        ForEach(
            Self.items(archivedCount: archivedCount),
            id: \.self
        ) { item in
            switch item {
            case .account:
                AccountButton(account: account)
            case .archive:
                ArchiveButton(
                    archivedCount: archivedCount,
                    isCompact    : isCompact
                )
            }
        }
    }

    private var ground: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors    : [Color("RestylingSidebar").opacity(0), Color("RestylingSidebar")],
                startPoint: .top,
                endPoint  : .bottom
            )
            .frame(height: Self.fadeHeight)
            .allowsHitTesting(false)
            Color("RestylingSidebar")
        }
    }

    /// AccountButton is the account's monogram in a quiet circle, a menu with the account's name and
    /// email, Settings… and Sign Out. Settings… opens the Settings window by the route the app menu's
    /// Settings… and ⌘, take (`SettingsCommands`); the app has no `Settings` scene for a `SettingsLink`.
    struct AccountButton: View {
        let account: MockAccount

        @Environment(\.openWindow)
        private var openWindow

        var body: some View {
            Menu {
                Button {} label: {
                    Text(account.name)
                    Text(account.email)
                }
                .disabled(true)
                Divider()
                ForEach(
                    Action.allCases,
                    id: \.self
                ) { action in
                    Button(action.title) { perform(action) }
                }
            } label: {
                Text(account.monogram)
                    .font(.system(
                        size  : 11,
                        weight: .semibold
                    ))
                    .foregroundStyle(.secondary)
                    .frame(
                        width : HouseFoot.accountSide,
                        height: HouseFoot.accountSide
                    )
                    .background(
                        .white.opacity(0.08),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Account")
            .accessibilityLabel("Account, \(account.name)")
        }

        /// Action is an item of the account's menu, under its header.
        enum Action: CaseIterable {
            case settings
            case signOut

            var title: String {
                switch self {
                case .settings: "Settings…"
                case .signOut : "Sign Out"
                }
            }
        }

        private func perform(_ action: Action) {
            switch action {
            case .settings:
                openWindow(id: SettingsView.windowID)
            case .signOut:
                // The mockup signs no one out.
                break
            }
        }
    }

    /// ArchiveButton is the archive's door and, in the full sidebar, its count, filling the width the
    /// account leaves. The pointer over it lights a quiet highlight. The mockup opens no archive.
    struct ArchiveButton: View {
        let archivedCount: Int
        let isCompact    : Bool

        @State private var isHovering = false

        var body: some View {
            Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "door.left.hand.closed")
                    if !isCompact {
                        Text("Archive · \(archivedCount)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(
                    minWidth : HouseFoot.accountSide,
                    maxWidth : isCompact ? nil : .infinity,
                    minHeight: HouseFoot.accountSide
                )
                .background(
                    .white.opacity(isHovering ? 0.06 : 0),
                    in: RoundedRectangle(
                        cornerRadius: 8,
                        style       : .continuous
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(Self.spokenLabel(archivedCount: archivedCount))
        }

        /// What VoiceOver says for the archive holding `archivedCount` workers.
        static func spokenLabel(archivedCount: Int) -> String {
            "Archive, \(archivedCount) workers"
        }
    }
}
