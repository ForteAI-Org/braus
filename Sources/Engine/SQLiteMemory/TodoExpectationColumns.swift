import EngineCore
import Foundation
import Memory
import PerceptionCore

/// TodoExpectationColumns stores structural predicates and parameter names, never literal task values.
/// Predicates requiring unrepresentable literals read back as withheld, including file name lists.
struct TodoExpectationColumns: Equatable {
    var kind: String
    var operand = "withheld"
    var parameter: String?
    var secondParameter: String?
    var appID: Int64?
    var subject: String?
    var state: String?
    var presence: Int64?

    static func encode(_ expectation: TaskResultCheck.Expectation?, taskID: Int64,
                       in handle: some SQLiteQuerying) throws -> Self? {
        guard let expectation else { return nil }
        var result = Self(kind: expectation.kind)
        if case .nothing = expectation { result.operand = "none"; return result }
        if case .withheld = expectation { return result }
        let inputs = try handle.query("""
            SELECT name,text_value FROM memory_task_values WHERE task_id = ? AND revision = (
                SELECT current_revision FROM memory_tasks WHERE task_id = ?) ORDER BY position
            """, [.integer(taskID), .integer(taskID)]) { (try $0.text(0) ?? "", try $0.text(1)) }
        func parameter(_ text: String) -> String? {
            if text.hasPrefix("{"), text.hasSuffix("}"), text.count > 2,
               !text.dropFirst().dropLast().contains(where: { $0 == "{" || $0 == "}" }) {
                let name = String(text.dropFirst().dropLast())
                return inputs.contains(where: { $0.0 == name }) ? name : nil
            }
            return inputs.first { $0.1 == text }?.0
        }
        let texts = expectation.texts
        guard !texts.isEmpty, texts.count <= 2,
              let first = parameter(texts[0]) else { return result }
        result.parameter = first
        if texts.count == 2 {
            guard let second = parameter(texts[1]) else { return Self(kind: expectation.kind) }
            result.secondParameter = second
        }
        switch expectation {
        case .noOtherFiles(_, let named) where !named.isEmpty: return Self(kind: expectation.kind)
        case .window(let app, _, let open):
            result.presence = open ? 1 : 0
            if let app {
                result.appID = try handle.query("SELECT app_id FROM brain_apps WHERE bundle_id = ?", [.text(app)]) {
                    $0.integer(0)
                }.first ?? nil
                if result.appID == nil { return Self(kind: expectation.kind) }
            }
        case .element(let app, _, let expect):
            if let app {
                result.appID = try handle.query("SELECT app_id FROM brain_apps WHERE bundle_id = ?", [.text(app)]) {
                    $0.integer(0)
                }.first ?? nil
                if result.appID == nil { return Self(kind: expectation.kind) }
            }
            switch expect {
            case .state(let state): result.state = state.rawValue
            case .present: result.presence = 1
            case .absent: result.presence = 0
            case .value: break
            }
        default: break
        }
        result.operand = "parameter"
        return result
    }

    func insert(itemID: Int64, revisionID: Int64, in tx: SQLiteTransaction) throws {
        try tx.execute("""
            INSERT INTO memory_todo_item_expectations (item_id,todo_revision_id,predicate_position,kind,operand,
                parameter_name,second_parameter_name,app_id,subject_key,expected_state,presence)
            VALUES (?,?,0,?,?,?,?,?,?,?,?)
            """, [.integer(itemID), .integer(revisionID), .text(kind), .text(operand),
                  parameter.map(SQLiteValue.text) ?? .null, secondParameter.map(SQLiteValue.text) ?? .null,
                  appID.map(SQLiteValue.integer) ?? .null, subject.map(SQLiteValue.text) ?? .null,
                  state.map(SQLiteValue.text) ?? .null, presence.map(SQLiteValue.integer) ?? .null])
    }

    static func read(itemID: Int64, revisionID: Int64?, in handle: some SQLiteQuerying) throws -> TaskResultCheck.Expectation? {
        guard let revisionID else { return nil }
        guard let stored = try handle.query("""
            SELECT e.kind,e.operand,e.parameter_name,e.second_parameter_name,a.bundle_id,e.expected_state,e.presence
            FROM memory_todo_item_expectations e LEFT JOIN brain_apps a ON a.app_id = e.app_id
            WHERE e.item_id = ? AND e.todo_revision_id = ? ORDER BY predicate_position
            """, [.integer(itemID), .integer(revisionID)], { row in
                (kind: try row.text(0) ?? "", operand: try row.text(1) ?? "", parameter: try row.text(2),
                 second: try row.text(3), app: try row.text(4), state: try row.text(5), presence: row.integer(6))
            }).first else { return nil }
        if stored.kind == "none" { return .nothing(reason: TaskResultCheck.Expectation.noReadableResultReason) }
        guard stored.operand == "parameter", let parameter = stored.parameter else { return .withheld(kind: stored.kind) }
        let first = "{\(parameter)}"
        let second = stored.second.map { "{\($0)}" }
        switch stored.kind {
        case "file_written": return .fileWritten(path: first)
        case "file_changed": return .fileChanged(path: first)
        case "file_unchanged": return .fileUnchanged(path: first)
        case "file_absent": return .fileAbsent(path: first)
        case "file_contains": if let second { return .fileContains(path: first, text: second) }
        case "file_moved": if let second { return .fileMoved(from: first, to: second) }
        case "file_copied": if let second { return .fileCopied(from: first, to: second) }
        case "no_other_files": return .noOtherFiles(folder: first, named: [])
        case "window": return .window(app: stored.app, title: first, open: stored.presence != 0)
        case "element":
            if let second { return .element(app: stored.app, label: first, expect: .value(second)) }
            if let state = stored.state.flatMap(ControlState.init(rawValue:)) {
                return .element(app: stored.app, label: first, expect: .state(state))
            }
            return .element(app: stored.app, label: first, expect: stored.presence == 0 ? .absent : .present)
        default: break
        }
        return .withheld(kind: stored.kind)
    }
}
