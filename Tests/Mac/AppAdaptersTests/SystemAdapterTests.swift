import AppAdapters
import EngineCore
import LocalMCP
import Testing

/// The System adapter on a fake transport: setters answer the previous value, a change the read-back
/// does not see is unverified, a value already set is a no-op, a prompt is a refusal.
@Suite("System adapter: appearance, volume, Wi-Fi")
struct SystemAdapterTests {

    @Test("Setting the appearance answers the previous one and reads the new one back")
    func appearance() async throws {
        let transport = FakeSystemTransport()
        let outcome = try await SystemAdapter(transport: transport).call("set_appearance",
                                                                         .object(["appearance": .string("dark")]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["appearance"] == .string("dark"))
        #expect(outcome.result["previous"] == .string("light"))
    }

    @Test("The appearance already set is a no-op with no write")
    func appearanceNoop() async throws {
        let transport = FakeSystemTransport()
        let outcome = try await SystemAdapter(transport: transport).call("set_appearance",
                                                                         .object(["appearance": .string("light")]))
        #expect(outcome.kind == .actedNoop)
        #expect(await transport.writes == 0)
    }

    @Test("A change the Mac accepts and does not apply is unverified")
    func unverified() async throws {
        let transport = FakeSystemTransport(ignoresWrites: true)
        let adapter = SystemAdapter(transport: transport)
        #expect(try await adapter.call("set_appearance", .object(["appearance": .string("dark")])).kind == .actedUnverified)
        #expect(try await adapter.call("set_volume", .object(["level": .number(70)])).kind == .actedUnverified)
        #expect(try await adapter.call("set_wifi", .object(["on": .bool(false)])).kind == .actedUnverified)
    }

    @Test("A change that would prompt for Automation is refused with the reason")
    func permission() async throws {
        let transport = FakeSystemTransport(permissionNeeded: true)
        let outcome = try await SystemAdapter(transport: transport).call("set_appearance",
                                                                         .object(["appearance": .string("dark")]))
        #expect(outcome == .refused("Allow Automation."))
    }

    @Test("Volume sets level and mute and answers the previous ones")
    func volume() async throws {
        let transport = FakeSystemTransport()
        let outcome = try await SystemAdapter(transport: transport).call("set_volume",
                                                                         .object(["level": .number(25), "muted": .bool(true)]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["level"] == .number(25))
        #expect(outcome.result["muted"] == .bool(true))
        #expect(outcome.result["previous"]["level"] == .number(40))
    }

    @Test("Volume without arguments, or mute on a device without one, is refused before any write")
    func volumeRefusals() async throws {
        let transport = FakeSystemTransport(muted: nil)
        let adapter = SystemAdapter(transport: transport)
        #expect(try await adapter.call("set_volume", .object([:])).kind == .refused)
        #expect(try await adapter.call("set_volume", .object(["muted": .bool(true)])).kind == .refused)
        #expect(await transport.writes == 0)
    }

    @Test("A Mac without Wi-Fi answers an honest miss")
    func noWifi() async throws {
        let adapter = SystemAdapter(transport: FakeSystemTransport(wifi: nil))
        #expect(try await adapter.call("get_wifi", .object([:])).kind == .honestMiss)
        #expect(try await adapter.call("set_wifi", .object(["on": .bool(true)])).kind == .honestMiss)
    }
}
