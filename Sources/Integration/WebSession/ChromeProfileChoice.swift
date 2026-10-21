//
//  ChromeProfileChoice.swift
//  Braus
//

/// ChromeProfileChoice is the paired Chrome profile a conversation chose: the Braus extension instance's random
/// ID in that profile, and the name the person confirmed for it on the instance's pairing page. It is never a
/// Chrome profile directory, which no extension API gives, nor a site's account.
public struct ChromeProfileChoice: Sendable, Hashable {

    public let instanceID: String
    public let label     : String

    public init(instanceID: String, label: String) {
        self.instanceID = instanceID
        self.label      = label
    }
}
