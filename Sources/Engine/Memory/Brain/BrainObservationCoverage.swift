//
//  BrainObservationCoverage.swift
//  Braus
//
//  Created by Ronaldo Zefi on 19/10/2026.
//

import EngineCore
import PerceptionCore

/// BrainObservationCoverage is what one observation could see, sealed into the observe command when
/// it is made: how complete the capture was, the surface it was taken of and the representation
/// that read it (the MacDriver's accessibility tree, the Seat's pixels with their accessibility
/// harvest, or the browser engine's page). The values are copied from the capture, never read back
/// from a stored sample row, whose status may still change after the application concluded.
///
/// Presence and absence are asymmetric. Every observation is evidence that what it shows is there;
/// only an observation that could have shown an anchor is evidence that the anchor is gone. So only
/// a coverage that `attestsAbsence` advances the Brain's clock and runs its decay. An observe
/// command without coverage (contract version 1) keeps the behavior it was decided under: every
/// substantial scene ticks.
public struct BrainObservationCoverage: Sendable, Equatable, Hashable {

    /// Representation is the reader that produced the observation. The raw values are the ones the
    /// command's `representation` argument stores; the known ones are `CallRoute.Route`'s.
    public enum Representation: String, Sendable, Equatable, Hashable, CaseIterable {
        case native
        case desktop
        case web
        case unknown

        /// The representation of a call route; nil (a call outside the routed tools) is unknown.
        public init(_ route: CallRoute.Route?) {
            switch route {
                case .native?  : self = .native
                case .desktop? : self = .desktop
                case .web?     : self = .web
                case nil       : self = .unknown
            }
        }
    }

    /// SpatialScope distinguishes a complete visible viewport from an attested whole structural surface.
    public enum SpatialScope: String, Sendable, Equatable, Hashable {
        case visible
        case wholeSurface = "whole_surface"
        /// Only for decoding historical version 2 commands with their original absence rule.
        case legacyWindow = "legacy_window"
    }

    public let spatialScope: SpatialScope
    public let completeness  : CaptureQuality.Completeness
    public let surface       : CaptureSurface
    public let representation: Representation

    public init(
        completeness  : CaptureQuality.Completeness,
        surface       : CaptureSurface,
        representation: Representation,
        spatialScope: SpatialScope = .visible
    ) {
        self.spatialScope   = spatialScope
        self.completeness   = completeness
        self.surface        = surface
        self.representation = representation
    }

    /// The coverage of a perceived capture: its quality's completeness (`unknown` for an
    /// inconsistent quality, which has no meaningful status), its surface, and the route the call
    /// ran on. The caller passes the route the capture was made on; a route that changed during
    /// the call (a MacDriver hand-back) is the caller's to resolve.
    public init(capture: CaptureQuality, surface: CaptureSurface, route: CallRoute.Route?) {
        self.init(
            completeness  : capture.inconsistency == nil ? capture.completeness : .unknown,
            surface       : surface,
            representation: Representation(route)
        )
    }

    /// Absence requires explicit whole-surface attestation. Reading every visible node cannot prove that an anchor
    /// outside a scrolled viewport disappeared. Historical version 2 commands keep their original window-wide rule.
    public var attestsAbsence: Bool {
        guard completeness == .complete, spatialScope != .visible else { return false }
        switch surface {
            case .window, .dialog, .sheet: break
            case .popupUnion, .unknown   : return false
        }
        switch representation {
            case .native, .desktop: return true
            case .web, .unknown   : return false
        }
    }
}
