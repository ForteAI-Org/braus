//
//  HouseFoot.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseFoot is the sidebar's foot: the account's monogram at the leading edge, a menu that holds
/// Settings and Sign Out. The archive is in the sidebar's toolbar (`HouseArchiveButton`).
///
/// It floats over the rooms, which scroll under it to the window's edge. It has no box of its own:
/// its ground is the sidebar's colour, solid behind the monogram and fading to clear over
/// `fadeHeight` above it, so a room passing under dissolves with no edge. The fade lets clicks
/// through to the rooms. Its height, fade included, is the inset the rooms scroll clear of.
struct HouseFoot: View {
    let account: MockAccount

    /// The height over which the foot's ground fades to clear, above the monogram.
    static let fadeHeight: CGFloat = 32

    /// The side of the account's round button.
    static let accountSide: CGFloat = 28

    var body: some View {
        AccountButton(account: account)
            .frame(
                maxWidth : .infinity,
                alignment: .leading
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
}
