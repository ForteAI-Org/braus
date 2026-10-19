//
//  ApplicationOpeningTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import Foundation
import Testing
import TestScratch
@testable import SeatBroker

private func app(_ name: String, running: Bool = false) -> TargetApp {
    TargetApp(pid: running ? 42 : nil, bundleID: "com.example.\(name)", name: name,
              bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), windows: [])
}

private let installed = [app("Photos"), app("Google Chrome"), app("Preview"), app("Pages"), app("Café")]

@Test func resolvesAnInstalledApplicationHoweverTheNameIsWritten() throws {
    #expect(try ApplicationOpening.resolve("Photos", in: installed).name == "Photos")
    #expect(try ApplicationOpening.resolve("  photos ", in: installed).name == "Photos")
    #expect(try ApplicationOpening.resolve("Photos.app", in: installed).name == "Photos")
    #expect(try ApplicationOpening.resolve("Cafe", in: installed).name == "Café")
    // Not a name anybody has: one installed name contains it, so it is meant.
    #expect(try ApplicationOpening.resolve("Chrome", in: installed).name == "Google Chrome")
}

@Test func refusesANameThatMatchesNothingAndOneThatMatchesSeveral() {
    func sentence(for name: String, in apps: [TargetApp] = installed) -> String {
        do {
            let resolved = try ApplicationOpening.resolve(name, in: apps)
            Issue.record("\(name) resolved to \(resolved.name) instead of being refused")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    let missing = sentence(for: "Microsoft Word")
    #expect(missing.contains("No installed application is named \"Microsoft Word\""))
    #expect(missing.contains("call apps with a shorter query, then open_session with the bundleID it lists"))
    #expect(!missing.contains("prompt"))

    // "P" starts Photos, Preview and Pages: the run is told which, by bundle identifier, so the
    // next decision can open one of them instead.
    let several = sentence(for: "P")
    #expect(several.contains("\"P\" names 3 installed applications"))
    #expect(several.contains("Pages — com.example.Pages; Photos — com.example.Photos; "
        + "Preview — com.example.Preview"))

    #expect(sentence(for: "   ").contains("No application was named"))
}

@Test func theCatalogIsNamesOnlyAndSaysWhatItLeftOut() {
    let line = ApplicationOpening.catalog(installed)
    #expect(line == "Café, Google Chrome, Pages, Photos, Preview")
    #expect(!line.contains("com.example"))
    #expect(!line.contains("/Applications"))

    // Two installs of one name are one offer; resolving the name is where
    // that ambiguity is answered, not here.
    #expect(ApplicationOpening.catalog([app("Photos"), app("Photos")]) == "Photos")

    let capped = ApplicationOpening.catalog(installed, limit: 2)
    #expect(capped.hasPrefix("Café, Google Chrome"))
    #expect(capped.contains("3 more that are not listed but can still be named"))
}

@Test func anApplicationThatCannotBeSeatedIsNamedWithTheDriverSentence() {
    let cause = SeatBrokerError.driver("The window is 3000×2000 pt and does not fit in the "
        + "1512×982 pt background display. Make it smaller and try again.")
    let error = ApplicationOpening.notSeated(app("Photos"), cause: cause)
    let message = error.localizedDescription
    #expect(message.contains("Photos opened but could not be seated on the background display."))
    #expect(message.contains("does not fit in the 1512×982 pt background display"))
}

@Test func resolvesAnApplicationByItsFileNameOrItsBundleIdentifier() throws {
    // Visual Studio Code's bundle calls it "Code"; the Finder and the person call it by its file.
    let code = TargetApp(pid: nil, bundleID: "com.microsoft.VSCode", name: "Code",
                         bundleURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), windows: [])
    let apps = installed + [code]
    #expect(try ApplicationOpening.resolve("Visual Studio Code", in: apps).bundleID == "com.microsoft.VSCode")
    #expect(try ApplicationOpening.resolve("com.microsoft.vscode", in: apps).name == "Code")
    #expect(try ApplicationOpening.resolve("Code", in: apps).name == "Code")
    // A part of any of its names is enough, as it is for the bundle's own name.
    #expect(try ApplicationOpening.resolve("Visual Studio", in: apps).bundleID == "com.microsoft.VSCode")
    #expect(ApplicationOpening.names(of: code).prefix(2) == ["Code", "Visual Studio Code"])
}

// MARK: Ranking

private func installedApp(
    _ name    : String,
    bundleID  : String,
    bundleName: String? = nil,
    version   : String? = nil,
    lastUsed  : Date? = nil,
    running   : Bool = false,
    file      : String? = nil
) -> TargetApp {
    TargetApp(pid: running ? 42 : nil, bundleID: bundleID, name: name,
              bundleURL: URL(fileURLWithPath: "/Applications/\(file ?? name).app"), windows: [],
              bundleName: bundleName, version: version, lastUsed: lastUsed)
}

private let proTools = installedApp("Pro Tools", bundleID: "com.avid.ProTools", bundleName: "Pro Tools",
                                    version: "26.4.1.179")

private func proToolsDeveloper(running: Bool = false, lastUsed: Date? = nil) -> TargetApp {
    installedApp("Pro Tools Developer", bundleID: "com.avid.ProToolsDeveloper", bundleName: "Pro Tools Developer",
                 version: "26.4.0.5", lastUsed: lastUsed, running: running)
}

private func refusal(for name: String, in apps: [TargetApp]) -> String {
    do {
        let resolved = try ApplicationOpening.resolve(name, in: apps)
        Issue.record("\(name) resolved to \(resolved.name) instead of being refused")
        return ""
    } catch {
        return error.localizedDescription
    }
}

@Test func proToolsResolvesByNameSpellingAndBundleIdentifierAndInitialsAskWhichOne() throws {
    let apps = installed + [proTools, proToolsDeveloper()]
    #expect(try ApplicationOpening.resolve("Pro Tools", in: apps).bundleID == "com.avid.ProTools")
    #expect(try ApplicationOpening.resolve("ProTools", in: apps).bundleID == "com.avid.ProTools")
    #expect(try ApplicationOpening.resolve("Pro Tools Developer", in: apps).bundleID == "com.avid.ProToolsDeveloper")
    #expect(try ApplicationOpening.resolve("com.avid.ProToolsDeveloper", in: apps).name == "Pro Tools Developer")

    // Both spell "PT" and neither is running: the person is asked, with what tells them apart.
    let initials = refusal(for: "PT", in: apps)
    #expect(initials.contains("\"PT\" names 2 installed applications: "
        + "Pro Tools — com.avid.ProTools 26.4.1.179; Pro Tools Developer — com.avid.ProToolsDeveloper 26.4.0.5."))
    #expect(initials.hasSuffix("ask the person which one they mean, naming these; "
        + "then call open_session with the chosen bundleID."))
}

@Test func theOnlyRunningOneOfTheBestTierIsMeant() throws {
    let apps = [proTools, proToolsDeveloper(running: true)]
    #expect(try ApplicationOpening.resolve("PT", in: apps).bundleID == "com.avid.ProToolsDeveloper")
    #expect(refusal(for: "PT", in: [proTools, proToolsDeveloper()]).contains("names 2 installed applications"))
    #expect(ApplicationOpening.described(proToolsDeveloper(running: true))
        == "Pro Tools Developer — com.avid.ProToolsDeveloper 26.4.0.5 (running)")
}

@Test func aBundleNameHiddenByTheDisplayNameStillNamesTheApplication() throws {
    // Without CFBundleName, "Code" only starts a word of both, and the two would be refused.
    let code   = installedApp("Visual Studio Code", bundleID: "com.microsoft.VSCode", bundleName: "Code")
    let editor = installedApp("Code Editor", bundleID: "com.example.CodeEditor")
    #expect(try ApplicationOpening.resolve("Code", in: [editor, code]).bundleID == "com.microsoft.VSCode")
    #expect(ApplicationOpening.names(of: code).contains("Code"))
    #expect(refusal(for: "Code", in: [editor, installedApp("Visual Studio Code", bundleID: "com.microsoft.VSCode")])
        .contains("names 2 installed applications"))
}

@Test func equalMatchesAreOrderedByRunningThenRecencyThenTheShorterName() {
    let apps = [proToolsDeveloper(), proTools]
    #expect(ApplicationOpening.ranked("PT", in: apps).map(\.name) == ["Pro Tools", "Pro Tools Developer"])
    #expect(ApplicationOpening.ranked("pro to", in: apps).first?.name == "Pro Tools")

    let recent = [proTools, proToolsDeveloper(lastUsed: Date(timeIntervalSince1970: 1_790_000_000))]
    #expect(ApplicationOpening.ranked("PT", in: recent).map(\.name) == ["Pro Tools Developer", "Pro Tools"])

    // A better match outranks recency, and no query lists every application in the tie order.
    #expect(ApplicationOpening.ranked("Pro Tools", in: recent).map(\.name) == ["Pro Tools", "Pro Tools Developer"])
    let running = installedApp("Slack", bundleID: "com.tinyspeck.slackmacgap", running: true)
    #expect(ApplicationOpening.ranked(nil, in: recent + [running]).map(\.name)
        == ["Slack", "Pro Tools Developer", "Pro Tools"])
    #expect(ApplicationOpening.ranked("Logic", in: recent).isEmpty)
}

private func product(_ bundleID: String, name: String, pid: pid_t? = nil) -> TargetApp {
    TargetApp(pid: pid, bundleID: bundleID, name: name,
              bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), windows: [])
}

@Test func theProductItselfIsNeverOpened() {
    let apps = installed + [product("dev.forte.Braus", name: "Braus"), product("dev.forte.Mecum", name: "Mecum")]
    for name in ["Braus", "mecum", "Braus.app", "dev.forte.Braus"] {
        #expect(throws: SeatBrokerError.self) { try ApplicationOpening.resolve(name, in: apps) }
    }
}

@Test func anyCopyOfTheProductIsOwn() {
    #expect(ApplicationOpening.isOwn(product("dev.forte.Braus", name: "Braus")))
    #expect(ApplicationOpening.isOwn(product("dev.forte.Mecum", name: "Mecum")))
    #expect(ApplicationOpening.isOwn(product("com.example.Renamed", name: "Renamed", pid: 7), processID: 7))
    #expect(!ApplicationOpening.isOwn(product("com.example.Photos", name: "Photos", pid: 8), processID: 7))
    #expect(!ApplicationOpening.isOwn(app("Photos")))
}

// MARK: Password managers

private let onePassword = installedApp("1Password", bundleID: "com.1password.1password")
private let passwords   = installedApp("Passwords", bundleID: "com.apple.Passwords")
private let keeper      = installedApp("Keeper Password Manager", bundleID: "com.keepersecurity.passwordmanager")

@Test func aPasswordManagerIsRefusedByNameOrBundleIdentifierInstalledOrNot() {
    let apps = installed + [onePassword, passwords, keeper]
    for name in ["1Password", "1password.app", "com.1password.1password", "Apple Passwords", "passwords",
                 "Keeper Password Manager", "com.keepersecurity.passwordmanager", "Bitwarden", "com.bitwarden.desktop",
                 "Proton Pass", "NordPass", "Dashlane", "LastPass", "Enpass"] {
        #expect(refusal(for: name, in: apps).hasPrefix("\"\(name.replacingOccurrences(of: ".app", with: ""))\" "
            + "is a password manager, and you never open one"))
    }
}

@Test func anEntryInsideALongerWordIsNotAPasswordManager() throws {
    let timekeeper = installedApp("Timekeeper", bundleID: "com.example.Timekeeper")
    let generator  = installedApp("Password Generator", bundleID: "com.example.PasswordGenerator")
    let apps = installed + [timekeeper, generator]
    #expect(try ApplicationOpening.resolve("Timekeeper", in: apps).bundleID == "com.example.Timekeeper")
    #expect(try ApplicationOpening.resolve("Password Generator", in: apps).bundleID == "com.example.PasswordGenerator")
    #expect(!ApplicationOpening.isPasswordManager(timekeeper))
    #expect(!ApplicationOpening.isPasswordManager(generator))
    #expect(ApplicationOpening.isPasswordManager(keeper))
    #expect(ApplicationOpening.isPasswordManager(installedApp("Proton Pass", bundleID: "me.proton.pass.electron")))
    // A localized name is the bundle identifier's to catch.
    #expect(ApplicationOpening.isPasswordManager(installedApp("Passwörter", bundleID: "com.apple.Passwords")))
}

@Test func keeperIsNamedOnlyAsItsPasswordManager() throws {
    let game = installedApp("Dungeon Keeper", bundleID: "com.example.DungeonKeeper")
    let apps = installed + [keeper, game]
    #expect(!ApplicationOpening.isPasswordManager(game))
    #expect(try ApplicationOpening.resolve("Dungeon Keeper", in: apps).bundleID == "com.example.DungeonKeeper")
    // "Keeper" alone is no refusal, and the password manager, listed nowhere, is never what it names.
    #expect(try ApplicationOpening.resolve("Keeper", in: apps).bundleID == "com.example.DungeonKeeper")
    let byBundle = installedApp("Keeper", bundleID: "com.keepersecurity.passwordmanager")
    let byName   = installedApp("Keeper Password Manager", bundleID: "com.example.Keeper")
    #expect(ApplicationOpening.isPasswordManager(byBundle))
    #expect(ApplicationOpening.isPasswordManager(byName))
}

@Test func aPasswordManagerIsListedNowhere() {
    let apps = installed + [onePassword, passwords, keeper]
    #expect(ApplicationOpening.ranked(nil, in: apps).map(\.name)
        == ApplicationOpening.ranked(nil, in: installed).map(\.name))
    #expect(ApplicationOpening.ranked("pass", in: apps).isEmpty)
    #expect(ApplicationOpening.catalog(apps) == "Café, Google Chrome, Pages, Photos, Preview")
    // A part of a name is never resolved to one either, and none is offered as nearby.
    let partial = refusal(for: "password", in: apps)
    #expect(partial.hasPrefix("No installed application is named \"password\"; call apps"))
}

// MARK: Paths

@Test func resolvesAnInstalledApplicationByItsPath() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let tool = TargetApp(pid: nil, bundleID: "com.example.Tool", name: "Tool",
                         bundleURL: home.appendingPathComponent("Applications/Tool.app"), windows: [])
    let apps = installed + [tool]
    #expect(try ApplicationOpening.resolve("/Applications/Photos.app", in: apps).name == "Photos")
    #expect(try ApplicationOpening.resolve("  /Applications/Photos.app/ ", in: apps).name == "Photos")
    #expect(try ApplicationOpening.resolve("/Applications/../Applications/Pages.app", in: apps).name == "Pages")
    #expect(try ApplicationOpening.resolve("~/Applications/Tool.app", in: apps).bundleID == "com.example.Tool")
}

@Test func aPathNoInstalledApplicationSitsAtIsRefusedWithTheWayToNameOne() {
    for path in ["/Applications/Missing.app", "/Applications/Photos.app/Contents/MacOS/Photos", "~"] {
        let sentence = refusal(for: path, in: installed)
        #expect(sentence.hasPrefix("No installed application is at \"\(path)\". Name it by the bundleID"))
        #expect(sentence.contains("then open_session with that bundleID"))
    }
}

@Test func aPathFollowsSymbolicLinksOnBothSides() throws {
    let folder = Scratch.directory("application-paths")
    let real = folder.appendingPathComponent("Real.app")
    let link = folder.appendingPathComponent("Link.app")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    func app(at url: URL) -> TargetApp {
        TargetApp(pid: nil, bundleID: "com.example.Real", name: "Real", bundleURL: url, windows: [])
    }
    #expect(try ApplicationOpening.resolve(link.path, in: installed + [app(at: real)]).bundleID == "com.example.Real")
    #expect(try ApplicationOpening.resolve(real.path, in: installed + [app(at: link)]).bundleID == "com.example.Real")
}

@Test func theProductAndAPasswordManagerAreRefusedAtTheirPathToo() {
    let apps = installed + [product("dev.forte.Braus", name: "Braus"),
                            installedApp("1Password", bundleID: "com.1password.1password")]
    #expect(refusal(for: "/Applications/Braus.app", in: apps)
        .hasPrefix("\"/Applications/Braus.app\" is the application you run in"))
    #expect(refusal(for: "/Applications/1Password.app", in: apps)
        .hasPrefix("\"/Applications/1Password.app\" is a password manager"))
}
