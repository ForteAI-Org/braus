//
//  TrackLabelAgreementTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/10/2026.
//

import ApplicationServices
import Foundation
import Testing
@testable import PerceptionCore
@testable import SeatSession

// The scene names a control with `cleanLabel` and the driver checks the control it acts on with
// `sameLabel`. The layers cannot share code, so this keeps their two rules in step.
@Test(arguments: ["Audio 13 - Audio Track ", "Shown. Audio 13", "Keys - Audio Track",
                  "Drums - Room - Audio Track ", " Plain ", "DRUMS BUS - Routing Folder Track ",
                  "Selected. FX BUS - Routing Folder Track "])
func theDriverRecognisesTheNameTheSceneGave(raw: String) {
    #expect(RemoteContentActuator<AXUIElement>.sameLabel(AccessibilityAugmentation.cleanLabel(raw), raw))
}

// Every suffix the scene drops is one the driver drops too.
@Test(arguments: AccessibilityAugmentation.roleSuffixes)
func theDriverDropsEverySuffixTheSceneDrops(suffix: String) {
    #expect(RemoteContentActuator<AXUIElement>.sameLabel("Kick", "Kick" + suffix))
}
