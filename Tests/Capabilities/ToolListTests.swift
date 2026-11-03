import Capabilities
import ChatCore
import Foundation
import Testing

@Suite
struct ToolListTests {
    private let core = [
        "open_session", "observe", "act", "type_text", "press_key", "menu", "batch", "plan", "end", "find", "call"
    ]

    @Test func harnessSearchOmitsDiscovery() {
        #expect(ToolList.names(attendance: .app, level: .act, loading: .harnessSearch).map(\.rawValue)
            == core.filter { !["find", "call"].contains($0) })
        #expect(ToolList.names(attendance: .client, level: .observe, loading: .harnessSearch).map(\.rawValue)
            == ["open_session", "observe"])
        #expect(ToolList.names(attendance: .app, level: .act, loading: .upfront).map(\.rawValue) == core)
    }

    @Test func fixedCoreOrder() {
        #expect(ToolList.core.map(\.rawValue) == core)
        for attendance in [ToolList.Attendance.app, .client, .none] {
            for level in [ToolList.Level.act, .actConnectors] {
                let list = ToolList(attendance: attendance, level: level)
                #expect(list.attendance == attendance)
                #expect(list.level == level)
                #expect(ToolList.names(attendance: attendance, level: level).map(\.rawValue) == core)
            }
        }
    }

    @Test func observeHasOnlyOpeningReadingAndDiscovery() {
        for attendance in [ToolList.Attendance.app, .client, .none] {
            #expect(ToolList.names(attendance: attendance, level: .observe).map(\.rawValue)
                == ["open_session", "observe", "find", "call"])
        }
    }

    @Test func repeatedCompositionHasIdenticalBytesAndNoHumanTools() throws {
        for attendance in [ToolList.Attendance.app, .client, .none] {
            for level in [ToolList.Level.observe, .act, .actConnectors] {
                let first = ToolList(attendance: attendance, level: level)
                #expect(first == ToolList(attendance: attendance, level: level))
                let names = ToolList.names(attendance: attendance, level: level)
                #expect(!names.contains { ["human_step", "ask_person"].contains($0.rawValue) })
                let bytes = try JSONEncoder().encode(names)
                let repeatedBytes = try JSONEncoder().encode(ToolList.names(attendance: attendance, level: level))
                #expect(bytes == repeatedBytes)
            }
        }
    }
}
