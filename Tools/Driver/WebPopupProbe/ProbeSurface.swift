//
//  ProbeSurface.swift
//  WebPopupProbe
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

/// ProbeSurface names the four ways the fixture can show its web page above the main window.
enum ProbeSurface: String, CaseIterable {
    case panel
    case sheet
    case modal
    case popover

    var buttonTitle: String {
        "Open \(rawValue)"
    }

    var windowTitle: String {
        "WebPopupProbe \(rawValue)"
    }
}
