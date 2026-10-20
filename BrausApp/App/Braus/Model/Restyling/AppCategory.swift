//
//  AppCategory.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// AppCategory is the kind of app a worker knows how to drive.
nonisolated enum AppCategory: CaseIterable, Sendable {
    case audio, video, design, web, files, general
}
