import ApplicationServices
@testable import AccessibilityFacts
import Foundation
import PerceptionCore
import Testing
import Synchronization

@Suite("Accessibility value admission")
struct LiveAccessibilityReaderTests {

    @Test("The default string read requests only AXValue", arguments: ["120.000", "", "  Tempo\n"])
    func unguardedString(value: String) {
        let requests = Mutex<[String]>([])
        let reader = LiveAccessibilityReader(copyAttributeValue: { _, name, result in
            requests.withLock { $0.append(name as String) }
            guard name as String == kAXValueAttribute else { return .cannotComplete }
            result.pointee = value as CFString
            return .success
        })

        #expect(reader.value(AXUIElementCreateApplication(0)) == value)
        #expect(requests.withLock { $0 } == [kAXValueAttribute])
    }

    @Test("The default numeric read requests only AXValue")
    func unguardedNumber() {
        let requests = Mutex<[String]>([])
        let reader = LiveAccessibilityReader(copyAttributeValue: { _, name, result in
            requests.withLock { $0.append(name as String) }
            guard name as String == kAXValueAttribute else { return .cannotComplete }
            result.pointee = NSNumber(value: 120)
            return .success
        })

        #expect(reader.numericValue(AXUIElementCreateApplication(0)) == 120)
        #expect(requests.withLock { $0 } == [kAXValueAttribute])
    }

    @Test("Guarded reads reject protected fields before AXValue", arguments: [
        "secure role", "secure subrole", "unreadable role", "unreadable subrole",
        "AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXPlaceholderValue"
    ], [false, true])
    func guardedValues(scenario: String, classified: Bool) {
        let requests = Mutex<[String]>([])
        let reader = LiveAccessibilityReader(
            valueGuard: { $0 == "Password" },
            copyAttributeValue: { _, attribute, result in
                let name = attribute as String
                requests.withLock { $0.append(name) }
                switch name {
                    case kAXRoleAttribute:
                        if scenario == "unreadable role" { return .cannotComplete }
                        result.pointee = (scenario == "secure role" ? "AXSecureTextField" : "AXTextField") as CFString
                    case kAXSubroleAttribute:
                        if scenario == "unreadable subrole" { return .cannotComplete }
                        result.pointee = (scenario == "secure subrole" ? "AXSecureTextField" : "") as CFString
                    case scenario:
                        result.pointee = "Password" as CFString
                    case kAXValueAttribute:
                        result.pointee = "must not be read" as CFString
                    default: return .noValue
                }
                return .success
            }
        )
        let node = AXUIElementCreateApplication(0)
        if classified {
            let role = reader.role(node), subrole = reader.subrole(node)
            #expect(reader.value(node, role: role, subrole: subrole) == nil)
            #expect(reader.numericValue(node, role: role, subrole: subrole) == nil)
        } else {
            #expect(reader.value(node) == nil)
            #expect(reader.numericValue(node) == nil)
        }
        #expect(!requests.withLock { $0 }.contains(kAXValueAttribute))
    }

    @Test("Guarded ordinary fields retain values", arguments: [AXError.success, .attributeUnsupported, .noValue], [false, true])
    func ordinaryGuardedValues(subroleAnswer: AXError, classified: Bool) {
        for numeric in [false, true] {
            let requests = Mutex<[String]>([])
            let reader = LiveAccessibilityReader(
                valueGuard: { $0 == "Password" },
                copyAttributeValue: { _, attribute, result in
                    let name = attribute as String
                    requests.withLock { $0.append(name) }
                    switch name {
                        case kAXRoleAttribute: result.pointee = "AXTextField" as CFString
                        case kAXSubroleAttribute:
                            result.pointee = "" as CFString
                            return subroleAnswer
                        case kAXValueAttribute:
                            result.pointee = numeric ? NSNumber(value: 120) : "120.000" as CFString
                        default: return .noValue
                    }
                    return .success
                }
            )
            let node = AXUIElementCreateApplication(0)
            if classified {
                let role = reader.role(node), subrole = reader.subrole(node)
                if numeric { #expect(reader.numericValue(node, role: role, subrole: subrole) == 120) }
                else { #expect(reader.value(node, role: role, subrole: subrole) == "120.000") }
                #expect(requests.withLock { $0 }.filter { $0 == kAXRoleAttribute }.count == 1)
                #expect(requests.withLock { $0 }.filter { $0 == kAXSubroleAttribute }.count == 1)
            } else if numeric {
                #expect(reader.numericValue(node) == 120)
            } else {
                #expect(reader.value(node) == "120.000")
            }
            #expect(requests.withLock { $0 }.filter { $0 == kAXValueAttribute }.count == 1)
        }
    }

    @Test("The guarded walker adds no non-text AX requests", arguments: ["AXButton", "AXCheckBox"], [false, true])
    func guardedWalkRequests(role: String, child: Bool) {
        func requests(guarded: Bool) -> [String] {
            let requests = Mutex<[String]>([])
            let valueGuard: (@Sendable (String) -> Bool)?
            if guarded { valueGuard = { _ in false } } else { valueGuard = nil }
            let reader = LiveAccessibilityReader(valueGuard: valueGuard,
                                                copyAttributeValue: { node, name, result in
                let isWindow = CFEqual(node, AXUIElementCreateApplication(0))
                let name = name as String
                if !child || !isWindow { requests.withLock { $0.append(name) } }
                switch name {
                    case kAXRoleAttribute: result.pointee = (child && isWindow ? "AXWindow" : role) as CFString
                    case kAXSubroleAttribute: return .attributeUnsupported
                    case kAXTitleAttribute: result.pointee = "Control" as CFString
                    case kAXValueAttribute: result.pointee = "1" as CFString
                    case kAXChildrenAttribute:
                        let children: [AXUIElement] = child && isWindow ? [AXUIElementCreateApplication(1)] : []
                        result.pointee = children as CFArray
                    case kAXPositionAttribute:
                        var point = CGPoint(x: 10, y: 10)
                        result.pointee = AXValueCreate(.cgPoint, &point)
                    case kAXSizeAttribute:
                        var size = CGSize(width: 30, height: 20)
                        result.pointee = AXValueCreate(.cgSize, &size)
                    default: return .noValue
                }
                return .success
            })
            let harvest = AccessibilityAugmentation.harvest(
                under: AXUIElementCreateApplication(0),
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100), reader: reader)
            #expect(harvest.elements.count == 1)
            return requests.withLock { $0 }
        }
        let names = requests(guarded: true)
        #expect(names == requests(guarded: false))
        #expect(names.filter { $0 == kAXRoleAttribute }.count == 1)
        #expect(names.filter { $0 == kAXSubroleAttribute }.count == (child ? 0 : 1))
        #expect(!names.contains(kAXHelpAttribute) && !names.contains(kAXPlaceholderValueAttribute))
        #expect(names.filter { $0 == kAXValueAttribute }.count == (role == "AXCheckBox" ? 2 : 1))
    }

    @Test("Unguarded values retain the existing transient retry", arguments: [false, true])
    func unguardedRetry(numeric: Bool) {
        let requests = Mutex<[String]>([])
        let reader = LiveAccessibilityReader(copyAttributeValue: { _, name, result in
            let count = requests.withLock { requests in
                requests.append(name as String)
                return requests.count
            }
            if count == 1 { return .cannotComplete }
            result.pointee = numeric ? NSNumber(value: 120) : "120.000" as CFString
            return .success
        })
        let node = AXUIElementCreateApplication(0)
        if numeric {
            #expect(reader.numericValue(node) == 120)
        } else {
            #expect(reader.value(node) == "120.000")
        }
        #expect(requests.withLock { $0 } == [kAXValueAttribute, kAXValueAttribute])
    }
}
