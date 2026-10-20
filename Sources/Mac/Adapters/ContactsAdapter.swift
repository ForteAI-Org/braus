@preconcurrency import Contacts
import EngineCore
import Foundation
import LocalMCP

/// StoreContact is one person of the Mac's address book, with the labelled phones and addresses an
/// agent needs to reach them.
public struct StoreContact: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let label: String?
        public let value: String

        public init(_ label: String?, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public let id          : String
    public let name        : String
    public let organization: String?
    public let phones      : [Entry]
    public let emails      : [Entry]
    public let addresses   : [Entry]
    /// The birthday as `YYYY-MM-DD`, or `--MM-DD` when the year is unknown.
    public let birthday    : String?

    public init(id: String, name: String, organization: String? = nil, phones: [Entry] = [], emails: [Entry] = [],
                addresses: [Entry] = [], birthday: String? = nil) {
        self.id           = id
        self.name         = name
        self.organization = organization
        self.phones       = phones
        self.emails       = emails
        self.addresses    = addresses
        self.birthday     = birthday
    }
}

public enum ContactsAccess: Sendable, Equatable {
    case granted, notDetermined, denied
}

extension ContactsStoring {
    public func requestAccess() async -> ContactsAccess { access() }
}

/// ContactsStoring is the address book as the Contacts adapter reaches it. The live one is
/// `MacContactsStore`; tests use an in-memory one.
public protocol ContactsStoring: Sendable {
    /// The access already granted; never prompts.
    func access() -> ContactsAccess
    /// Asks for access, prompting when the person has not answered yet.
    func requestAccess() async -> ContactsAccess
    /// The people whose name matches, as Contacts matches names (any part, without case).
    func contacts(matching name: String) async throws -> [StoreContact]
    func contact(id: String) async throws -> StoreContact?
}

/// ContactsAdapter is the Mac's address book through the Contacts framework, with Contacts closed:
/// who a person is and how to reach them, so a mail or a message goes to an address read from it.
/// It only reads.
public struct ContactsAdapter: AppAdapting {

    public let name       = "contacts"
    public let appNames   = ["Contacts", "Contatti", "Address Book", "Rubrica"]
    public let bundleIDs: Set<String> = ["com.apple.AddressBook"]

    /// The most people one answer lists.
    static let maximumContacts = 20
    /// Who a person is and how to reach them: an entry's `value` (a phone, an address), not its label; ids and
    /// counts stay recorded.
    static let contentResults = ["name", "organization", "value", "birthday"]

    private let store: any ContactsStoring

    public init(store: any ContactsStoring) {
        self.store = store
    }

    public var verbs: [AdapterVerb] {
        [
            AdapterVerb("find_contacts", "Find people by name, with their phones and email addresses.",
                        parameters: [
                            AdapterParameter("name", .string, "a name or part of one", confidential: .sensitiveMetadata),
                            AdapterParameter("limit", .integer, "at most this many; default 10", required: false,
                                             range: 1...Double(Self.maximumContacts)),
                        ],
                        safety: .read, readBack: "the address book", contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("read_contact", "Read one person: phones, emails, postal addresses, organization, birthday.",
                        parameters: [AdapterParameter("id", .string, "the contact's id from find_contacts")],
                        safety: .read, readBack: "the address book by the contact's id",
                        contentResults: Self.contentResults, results: .identifiersAndDates),
        ]
    }

    public func availability() async -> AdapterAvailability {
        Self.availability(store.access())
    }

    public func requestPermission() async -> AdapterAvailability {
        Self.availability(await store.requestAccess())
    }

    static func availability(_ access: ContactsAccess) -> AdapterAvailability {
        switch access {
            case .granted: .ready
            case .notDetermined, .denied:
                .needsPermission("Braus has no access to Contacts. The person grants it in System Settings > "
                                 + "Privacy & Security > Contacts, for the app Braus runs in.")
        }
    }

    public func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        let arguments = AdapterArguments(arguments)
        switch verb {
            case "find_contacts":
                let wanted = try arguments.required("name").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wanted.isEmpty else { return .refused("name is empty.") }
                let limit  = arguments.number("limit").map { Int($0) } ?? 10
                let people = try await store.contacts(matching: wanted)
                guard !people.isEmpty else { return .missing("Nobody named \(wanted) in Contacts.") }
                let listed = people.prefix(limit)
                return .confirmed("\(people.count) \(people.count == 1 ? "person" : "people") named \(wanted)"
                                  + (people.count > listed.count ? "; the first \(listed.count) listed." : "."),
                                  .object(["contacts": .array(listed.map { Self.json($0, full: false) }),
                                           "total": .number(Double(people.count))]))
            case "read_contact":
                let id = try arguments.required("id")
                guard let person = try await store.contact(id: id) else { return .missing("No contact with id \(id).") }
                return .confirmed("\(person.name).", Self.json(person, full: true))
            default:
                throw AdapterFailure("contacts has no verb \(verb).")
        }
    }

    static func json(_ person: StoreContact, full: Bool) -> JSONValue {
        func entries(_ list: [StoreContact.Entry]) -> JSONValue {
            .array(list.map { .object(["label": $0.label.map(JSONValue.string) ?? .null, "value": .string($0.value)]) })
        }
        var object: [String: JSONValue] = [
            "id"          : .string(person.id),
            "name"        : .string(person.name),
            "organization": person.organization.map(JSONValue.string) ?? .null,
            "phones"      : entries(person.phones),
            "emails"      : entries(person.emails),
        ]
        if full {
            object["addresses"] = entries(person.addresses)
            object["birthday"]  = person.birthday.map(JSONValue.string) ?? .null
        }
        return .object(object)
    }
}

/// MacContactsStore reads the Mac's address book through `CNContactStore`. Only `requestAccess()`, on
/// the person's request, asks for access: without it, the adapter answers `needsPermission`.
public final class MacContactsStore: ContactsStoring, @unchecked Sendable {

    // CNContactStore is safe to share for reads; nothing here mutates it.
    private let store = CNContactStore()

    public init() {}

    public func access() -> ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized   : .granted
            case .notDetermined: .notDetermined
            default            : .denied
        }
    }

    public func requestAccess() async -> ContactsAccess {
        guard access() == .notDetermined else { return access() }
        _ = try? await store.requestAccess(for: .contacts)
        return access()
    }

    private static let keys: [any CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactOrganizationNameKey as any CNKeyDescriptor, CNContactPhoneNumbersKey as any CNKeyDescriptor,
        CNContactEmailAddressesKey as any CNKeyDescriptor, CNContactPostalAddressesKey as any CNKeyDescriptor,
        CNContactBirthdayKey as any CNKeyDescriptor,
    ]

    public func contacts(matching name: String) async throws -> [StoreContact] {
        try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: Self.keys)
            .map(Self.contact)
    }

    public func contact(id: String) async throws -> StoreContact? {
        try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: [id]), keysToFetch: Self.keys)
            .first.map(Self.contact)
    }

    private static func contact(_ person: CNContact) -> StoreContact {
        func label(_ raw: String?) -> String? { raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } }
        let name = CNContactFormatter.string(from: person, style: .fullName) ?? ""
        let birthday = person.birthday.map { parts in
            let month = String(format: "%02d", parts.month ?? 0), day = String(format: "%02d", parts.day ?? 0)
            return parts.year.map { "\(String(format: "%04d", $0))-\(month)-\(day)" } ?? "--\(month)-\(day)"
        }
        return StoreContact(
            id          : person.identifier,
            name        : name.isEmpty ? person.organizationName : name,
            organization: person.organizationName.isEmpty ? nil : person.organizationName,
            phones      : person.phoneNumbers.map { .init(label($0.label), $0.value.stringValue) },
            emails      : person.emailAddresses.map { .init(label($0.label), $0.value as String) },
            addresses   : person.postalAddresses.map {
                .init(label($0.label), CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress))
            },
            birthday    : birthday)
    }
}
