//
//  BrainLibrary.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import AutomationRuntime
import Foundation
import Memory

/// BrainAppSummary identifies an application without loading its stored Brain.
struct BrainAppSummary: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var observationSummary: StoredBrainSummary? = nil

    var id: String { bundleID }
}

/// BrainLibraryState is what the Brain page can show: the applications the living memory holds a
/// Brain of, possibly none yet, or an archive that cannot be read, with the reason, which is never
/// shown as an empty Brain.
enum BrainLibraryState {
    case loaded([BrainAppSummary])
    case unavailable(String)
}

/// BrainLibrary reads the Brain from the living memory of the knowledge directory the workers and the
/// command line share: the process's own `MemoryService` for it, which reads without waiting for a
/// worker writing at the same time. A directory with no archive yet holds no Brain, and reading it
/// creates nothing.
enum BrainLibrary {

    static func apps(in directory: URL) async -> BrainLibraryState {
        let memory = MemoryService.shared(for: directory)
        guard memory.archiveExists else { return .loaded([]) }
        do {
            let summaries = try await memory.storedBrainSummaries()
            return .loaded(summaries.map { summary in
                var item = app(bundleID: summary.bundleID)
                item.observationSummary = summary
                return item
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            return .unavailable(MemoryService.describe(error))
        }
    }

    static func apps(applications: () async throws -> [String]) async -> BrainLibraryState {
        do {
            let apps = try await applications().map { app(bundleID: $0) }
            return .loaded(apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            return .unavailable(MemoryService.describe(error))
        }
    }

    private static func app(bundleID: String) -> BrainAppSummary {
        let url      = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name     = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        return BrainAppSummary(
            bundleID : bundleID,
            name     : name ?? bundleID,
            icon     : url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        )
    }
}
