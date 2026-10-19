//
//  AdapterApprovalSheet.swift
//  Braus
//

import AppAdapters
import Foundation
import LocalMCP
import SwiftUI

/// AdapterApprovalSheet asks the person whether one irreversible adapter call can run: what it would do in words,
/// and its arguments as "Key: value" rows, each text already cut to its first lines (`AdapterConsent`).
///
/// Don’t Allow, or Escape, refuses the call and nothing is done; Allow Once runs it. It asks each time. No button
/// is the default, so Return answers nothing, and every button waits until `answerableAt`, about a second after
/// the request appeared, so a key or a click meant for something else cannot answer it. Everything shown was
/// chosen by the model: it is shown, never followed.
struct AdapterApprovalSheet: View {

    let pending     : AdapterApprovals.Pending
    let answerableAt: ContinuousClock.Instant?
    let allowOnce   : () -> Void
    let refuse      : () -> Void

    @State private var isAnswerable = false

    private var consent: AdapterConsent { pending.consent }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 14
        ) {
            header
            arguments
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
        // Each request starts with its buttons off, whatever the last one left.
        .task(id: pending.id) {
            isAnswerable = false
            if let answerableAt {
                do {
                    try await Task.sleep(
                        until: answerableAt,
                        clock: .continuous
                    )
                } catch {
                    return
                }
            }
            isAnswerable = true
        }
    }

    private var header: some View {
        HStack(
            alignment: .top,
            spacing  : 12
        ) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(
                alignment: .leading,
                spacing  : 4
            ) {
                Text("\(consent.app) wants to \(consent.verb.replacingOccurrences(of: "_", with: " "))")
                    .font(.title3.weight(.semibold))
                    .fixedSize(
                        horizontal: false,
                        vertical  : true
                    )
                    .accessibilityAddTraits(.isHeader)

                Text("This may change or delete data in \(consent.app). Braus asks each time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(
                        horizontal: false,
                        vertical  : true
                    )
            }
        }
    }

    @ViewBuilder
    private var arguments: some View {
        if consent.arguments.isEmpty {
            Text("The call has no arguments.")
                .foregroundStyle(.secondary)
        } else {
            Grid(
                alignment        : .leadingFirstTextBaseline,
                horizontalSpacing: 10,
                verticalSpacing  : 6
            ) {
                ForEach(consent.arguments.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(Self.words(key) + ":")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(Self.text(consent.arguments[key] ?? .null))
                            .lineLimit(AdapterConsent.excerptLines)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
            .background(
                .quinary,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }

    private var buttons: some View {
        HStack {
            Button(
                "Don’t Allow",
                role  : .cancel,
                action: refuse
            )
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(
                "Allow Once",
                action: allowOnce
            )
        }
        .disabled(!isAnswerable)
        .padding(.top, 4)
    }

    /// A key as words, its first letter capitalized: `event_id` gives "Event id".
    private static func words(_ key: String) -> String {
        let phrase = key.replacingOccurrences(of: "_", with: " ")
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    /// A value as the person reads it: a text as it is, anything else as JSON.
    private static func text(_ value: JSONValue) -> String {
        if let string = value.string { return string }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(
            decoding: data,
            as      : UTF8.self
        )
    }
}
