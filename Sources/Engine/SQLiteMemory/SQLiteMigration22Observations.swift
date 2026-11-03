import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteMigration22Observations derives shared content and skeleton digests from already converted rows.
/// It runs before history guards, preserving all source observations and processing one sample or scene at a time.
enum SQLiteMigration22Observations {
    @discardableResult
    static func convert(in db: SQLiteConnection) throws -> Int {
        guard db.isInTransaction else { throw refusal("observation transaction") }
        let captures = try db.prepare("""
            SELECT observation_id,status,surface_kind FROM memory_event_observations
            WHERE observation_kind='capture' ORDER BY observation_id
            """)
        defer { captures.finalize() }
        var count = 0
        while try captures.step() {
            try Task.checkCancellation()
            guard let id = captures.row.integer(0) else { throw refusal("capture identity") }
            let status = try captures.row.text(1)
            let surface = try captures.row.text(2)
            let elements = try db.query("""
                SELECT role,element_kind,label,label_origin,container_path,new_state
                FROM memory_event_observations WHERE parent_observation_id=? AND observation_kind='element'
                ORDER BY observation_id
                """, [.integer(id)]) { row in try (0...5).map { try row.text($0) } }
            let members = try elements.map { try SQLiteElementSetRows.element(in: db, fields: $0) }
            let set = try SQLiteElementSetRows.set(in: db, members: members)
            let subrole = try db.query("""
                SELECT text_value FROM memory_event_observations
                WHERE parent_observation_id=? AND observation_kind='capture_field' AND field_name='window_subrole'
                """, [.integer(id)]) { try $0.text(0) }.first ?? nil
            let reason: SQLiteValue
            if status != "complete" { reason = .text("incomplete") }
            else if surface == "unknown" || surface == "popup_union" { reason = .text("uncertain_surface") }
            else { reason = .null }
            try db.run("""
                UPDATE memory_event_observations SET set_id=?,window_subrole=?,reject_reason=? WHERE observation_id=?
                """, [.integer(set),subrole.map(SQLiteValue.text) ?? .null,reason,.integer(id)])
            count += 1
        }
        try scenes(in: db)
        return count
    }

    private struct Element {
        let id: Int64
        let parent: Int64?
        let key: String
        let scope: String
        let role: String?
        let kind: String?
        let label: String?
        let origin: String?
    }

    private static func scenes(in db: SQLiteConnection) throws {
        let scenes = try db.prepare("SELECT scene_id,scene_kind FROM brain_scenes WHERE scene_kind<>'app' ORDER BY scene_id")
        defer { scenes.finalize() }
        while try scenes.step() {
            try Task.checkCancellation()
            guard let id = scenes.row.integer(0),
                  let surface = try scenes.row.text(1).flatMap(CaptureSurface.init(rawValue:)) else {
                throw refusal("scene identity or surface")
            }
            let elements = try db.query("""
                SELECT scene_element_id,parent_element_id,element_key,element_scope,role,kind,label,label_origin
                FROM brain_scene_elements WHERE scene_id=? ORDER BY scene_element_id
                """, [.integer(id)]) { row in
                    Element(id: row.integer(0) ?? 0, parent: row.integer(1), key: try row.text(2) ?? "",
                            scope: try row.text(3) ?? "", role: try row.text(4), kind: try row.text(5),
                            label: try row.text(6), origin: try row.text(7))
                }
            var paths: [Int64: String] = [:]
            for element in elements where element.scope == "container" || element.scope == "collection" {
                let prefix = element.scope + "|"
                guard element.key.hasPrefix(prefix) else { throw refusal("scene container path") }
                paths[element.id] = String(element.key.dropFirst(prefix.count))
            }
            var roles: [String: Set<String>] = [:]
            var captions: [String: Set<SceneSkeleton.Caption>] = [:]
            var collections: Set<String> = []
            var members: [Int64] = []
            for element in elements where element.scope != "container" {
                let path: String
                if let parent = element.parent {
                    guard let found = paths[parent] else { throw refusal("scene element parent path") }
                    path = found
                } else { path = "" }
                members.append(try SQLiteElementSetRows.element(
                    in: db, fields: [element.role,element.kind,element.label,element.origin,path,nil]
                ))
                switch element.scope {
                case "collection":
                    guard let collection = paths[element.id] else { throw refusal("scene collection path") }
                    collections.insert(collection)
                case "item_template": break
                case "control":
                    guard let role = element.role, !role.isEmpty else { throw refusal("scene control role") }
                    roles[path, default: []].insert(role)
                    if let code = element.origin {
                        guard let origin = LabelOrigin(rawValue: code) else { throw refusal("scene label origin") }
                        if SceneSkeleton.captionRoles.contains(role), SceneSkeleton.captionOrigins.contains(origin) {
                            guard let label = element.label else { throw refusal("scene caption") }
                            captions[path, default: []].insert(.init(role: role, label: label))
                        }
                    }
                default: throw refusal("scene element scope")
                }
            }
            let skeleton = SceneSkeleton(surface: surface, rolesByPath: roles, captionsByPath: captions, collections: collections)
            let set = try SQLiteElementSetRows.set(in: db, members: members)
            try db.run("UPDATE brain_scenes SET set_id=?,skeleton_digest=? WHERE scene_id=?",
                       [.integer(set),.blob(Array(SkeletonDigest(skeleton).bytes)),.integer(id)])
        }
    }

    private static func refusal(_ reason: String) -> SQLiteMigration22.Refusal {
        .verificationFailed([reason])
    }
}
