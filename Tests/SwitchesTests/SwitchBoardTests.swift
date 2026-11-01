import Switches
import Testing

struct SwitchBoardTests {
    enum Arm: String, Sendable { case v1, v2 }

    @Test func defaultsAndInvalidValues() {
        #expect(SwitchBoard().arm("outcome", default: Arm.v1) == .v1)
        let board = SwitchBoard.fromEnvironment(["BRAUS_SWITCHES": "outcome=v2,unknown-test=bad"])
        #expect(board.arm("outcome", default: Arm.v1) == .v2)
        #expect(board.arm("unknown-test", default: Arm.v1) == .v1)
        #expect(SwitchBoard.invalid["unknown-test"] == "bad")
    }

    @Test func installsProcessBoard() {
        let board = SwitchBoard.current
        SwitchBoard.install(board)
        #expect(SwitchBoard.current == board)
    }

    @Test func testingWinsAndIsScoped() {
        let before = SwitchBoard.current
        let board = SwitchBoard(values: ["outcome": "v2"])
        SwitchBoard.$testing.withValue(board) {
            #expect(SwitchBoard.current == board)
            SwitchBoard.$testing.withValue(SwitchBoard()) {
                #expect(SwitchBoard.current.values.isEmpty)
            }
            #expect(SwitchBoard.current == board)
        }
        #expect(SwitchBoard.current == before)
    }
}
