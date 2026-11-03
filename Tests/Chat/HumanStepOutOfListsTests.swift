@testable import AutomationMCP
import AutomationRuntime
import CryptoKit
import Foundation
import LocalMCP
import Switches
import Testing

@MainActor
struct HumanStepOutOfListsTests {
    @Test func everySurfaceExcludesHumanStep() {
        for bits in 0..<8 {
            for surface in ["v1", "v2"] {
                for cycle in ["v1", "v2"] {
                    SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": surface, "task_cycle": cycle])) {
                        let definitions = AutomationTools.definitions(for: AutomationChannels(rawValue: bits))
                        #expect(!definitions.contains { $0["name"].string == "human_step" })
                    }
                }
            }
        }
    }

    @Test func legacyGoldensOnlyRemoveHumanStep() throws {
        // These digests retain the original bytes after removing only the excluded definition.
        let approved = [
            "tools-adapters.json": "a85f1c721f556c177c133a6e91755114734205ade99c855e430c1446f8118d66",
            "tools-native-adapters.json": "4094b6411832b3762a4dfbd3bb08fc57b8e321cbbc2be782e918b9f03b179100",
            "tools-native-web-adapters.json": "24a4c4fc4e2b2fee4e0c08e3700536dfebc8c63b9c5c8fe31ce855c645f7f1d2",
            "tools-native-web.json": "fe1b0e447c7f99be6b182447caa12fc01dd1b4c297078291ad1b4cc606c9caf6",
            "tools-native.json": "978170bf036670810b951be127a16a85cb2a681551a59bfc100c91980bc2c5b6",
            "tools-none.json": "0ddaa80d6f32685de9b18980400b5ea397cd021054504474f33f73c6824e49b6",
            "tools-web-adapters.json": "bf5565201fd3810038cfe3f599ae66e05ef59b615f85f7a180496360e9ac7c49",
            "tools-web.json": "1202818f6bec1b863eccf64f1b946036b7bf8a38fce35cf003717a0e55497675"
        ]
        let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Golden")
        for (name, digest) in approved {
            let data = try Data(contentsOf: directory.appending(path: name))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest)
        }
    }
}
