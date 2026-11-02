//
//  ModifiedClickPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import SeatCore

/// ModifiedClickPlatform is another platform's recipe with modifier flags
/// stamped on every event it decorates, so a click is posted with them held on
/// its down and its up (a routing gesture is a Shift and Option click).
///
/// It exists because `InputCommand.click` carries no modifiers, and the click
/// keeps that vocabulary: everything else is the wrapped platform's answer, so
/// the Preparation, the settle and the route are the ones the family already has.
nonisolated package struct ModifiedClickPlatform: InputPlatform {

    package let base     : any InputPlatform
    package let modifiers: Modifiers

    package init(
        _ base   : any InputPlatform,
        modifiers: Modifiers
    ) {
        self.base      = base
        self.modifiers = modifiers
    }

    package func preparation(for command: InputCommand) -> Preparation {
        base.preparation(for: command)
    }

    package func preparationSettle(for command: InputCommand) -> Duration {
        base.preparationSettle(for: command)
    }

    package func keyWindowPriming(for command: InputCommand) -> (host: WindowReference, settle: Duration)? {
        base.keyWindowPriming(for: command)
    }

    package var dragPacing: DragPacing { base.dragPacing }

    package func modifierPolicy(for command: InputCommand) -> ModifierPolicy {
        base.modifierPolicy(for: command)
    }

    package var keyRepeatPacing: KeyRepeatPacing { base.keyRepeatPacing }

    package func windowArrivalHorizon(after command: InputCommand) -> Duration {
        base.windowArrivalHorizon(after: command)
    }

    /// The wrapped platform's field first, then the flags, written whole so a
    /// state the private source kept from an earlier event does not leak in.
    package func decorate(_ event: CGEvent, for command: InputCommand) {
        base.decorate(event, for: command)
        event.flags = modifiers.cgFlags
    }
}
