//
//  InteractionStructuralRead.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation

/// InteractionStructuralRead is one accessibility read of a lent process's windows for the intervention report: whole
/// collections with how much was read, editable fields, content other processes host, and what stopped the read.
package struct InteractionStructuralRead: Codable, Sendable, Equatable {
    /// How much of a collection a read covers. A removal can be claimed only inside the covered part.
    package enum Coverage: Codable, Sendable, Equatable {
        /// Every member, and the count agrees.
        case complete
        /// Members `first...last` by index; the rest was not read.
        case range(first: Int, last: Int)
        /// Only what is on screen: the application exposes no more.
        case viewport
    }

    package struct Member: Codable, Sendable, Equatable {
        package var index: Int
        /// The member's name field: its title or description, else its first cell's text.
        package var name: String?
        package var identifier: String?
        /// A file name or URL the member exposes.
        package var document: String?
        package var role: String?
        package var selected: Bool?

        package init(index: Int, name: String? = nil, identifier: String? = nil, document: String? = nil,
                     role: String? = nil, selected: Bool? = nil) {
            self.index = index
            self.name = name
            self.identifier = identifier
            self.document = document
            self.role = role
            self.selected = selected
        }
    }

    package struct Collection: Codable, Sendable, Equatable {
        package var role: String
        package var name: String?
        package var identifier: String?
        package var count: Int?
        package var members: [Member]
        package var coverage: Coverage
        /// Indexes of the members on screen, when the application exposes them.
        package var visible: [Int]

        package init(role: String, name: String?, identifier: String?, count: Int?, members: [Member], coverage: Coverage,
                     visible: [Int]) {
            self.role = role
            self.name = name
            self.identifier = identifier
            self.count = count
            self.members = members
            self.coverage = coverage
            self.visible = visible
        }
    }

    package struct Field: Codable, Sendable, Equatable {
        package var role: String
        package var name: String?
        package var identifier: String?
        package var value: String?
        /// The names of its nearest named ancestors below the window, " / " between them ("Track 1 / Audio IO"): what
        /// tells apart fields of one name, one per track or row. Absent in older archives.
        package var container: String?

        package init(role: String, name: String?, identifier: String?, value: String?, container: String? = nil) {
            self.role = role
            self.name = name
            self.identifier = identifier
            self.value = value
            self.container = container
        }
    }

    /// Content another process hosts inside the window (a view service, an extension). Read when it answers;
    /// otherwise an unobserved region named by its host.
    package struct Region: Codable, Sendable, Equatable {
        package var processID: Int32
        package var host: String?
        package var role: String?
        package var name: String?
        package var read: Bool

        package init(processID: Int32, host: String?, role: String?, name: String?, read: Bool) {
            self.processID = processID
            self.host = host
            self.role = role
            self.name = name
            self.read = read
        }
    }

    /// What stopped the read, so a partial read is stated as partial.
    package struct Quality: Codable, Sendable, Equatable {
        package var deadline = false
        package var elementBudget = false
        package var depth = false
        /// Collections whose members did not answer.
        package var unanswered = 0
        /// Fields found whose value the time box left unread; absent in older archives.
        package var skippedFields: Int? = nil

        package init() {}
    }

    package struct Window: Codable, Sendable, Equatable {
        package var number: Int?
        package var title: String?
        package var elements = 0
        package var collections: [Collection] = []
        package var fields: [Field] = []
        package var hosted: [Region] = []
        package var quality = Quality()

        package init(number: Int?, title: String?) {
            self.number = number
            self.title = title
        }
    }

    package var processID: Int32
    package var interval: InteractionSemanticSnapshot.Interval
    package var windows: [Window]
    /// Windows in scope that no read reached: "never read" is stated, never inferred.
    package var unread: [Int]

    package init(processID: Int32, interval: InteractionSemanticSnapshot.Interval, windows: [Window] = [], unread: [Int] = []) {
        self.processID = processID
        self.interval = interval
        self.windows = windows
        self.unread = unread
    }

    package func withholding(_ transform: (String) -> String) -> Self {
        var result = self
        for index in result.windows.indices {
            result.windows[index].title = result.windows[index].title.map(transform)
            for collection in result.windows[index].collections.indices {
                result.windows[index].collections[collection].name = result.windows[index].collections[collection].name.map(transform)
                for member in result.windows[index].collections[collection].members.indices {
                    var value = result.windows[index].collections[collection].members[member]
                    value.name = value.name.map(transform)
                    value.document = value.document.map(transform)
                    result.windows[index].collections[collection].members[member] = value
                }
            }
            for field in result.windows[index].fields.indices {
                result.windows[index].fields[field].name = result.windows[index].fields[field].name.map(transform)
                result.windows[index].fields[field].value = result.windows[index].fields[field].value.map(transform)
                result.windows[index].fields[field].container = result.windows[index].fields[field].container.map(transform)
            }
            for region in result.windows[index].hosted.indices {
                result.windows[index].hosted[region].name = result.windows[index].hosted[region].name.map(transform)
            }
        }
        return result
    }
}
