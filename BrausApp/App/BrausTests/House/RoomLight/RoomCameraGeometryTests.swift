import CoreGraphics
import Testing
@testable import Braus

@Suite("Room camera geometry")
struct RoomCameraGeometryTests {

    @Test("An unlaid-out room does not publish a face projection")
    func invalidDimensions() {
        let sizes: [CGSize] = [
            .zero,
            CGSize(width: 0, height: 104),
            CGSize(width: 127, height: 0),
            CGSize(width: -1, height: 104),
            CGSize(width: 127, height: -1),
            CGSize(width: CGFloat.nan, height: 104),
            CGSize(width: 127, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: 104),
            CGSize(width: 127, height: CGFloat.infinity),
        ]
        for size in sizes {
            for shape in WorkerShape.allCases {
                #expect(RoomCamera.tilted.face(of: shape, in: size) == nil)
            }
        }
    }

    @Test("A non-finite lean does not enter the projection cache")
    func invalidLean() {
        for lean in [Float.nan, .infinity, -.infinity] {
            #expect(RoomCamera.tilted.face(of: .circle, in: CGSize(width: 127, height: 104), lean: lean) == nil)
        }
    }

    @Test("A positive size whose sphere radius underflows does not publish NaN scales")
    func collapsedRadius() {
        let width = CGFloat(Double(Float.leastNonzeroMagnitude) / 4)
        #expect(width > 0)
        #expect(RoomCamera.tilted.face(of: .circle, in: CGSize(width: width, height: 104)) == nil)
    }

    @Test("A valid layout after an empty layout restores the projected face")
    func layoutRecovers() throws {
        for shape in WorkerShape.allCases {
            #expect(RoomCamera.tilted.face(of: shape, in: .zero) == nil)
            let face = try #require(RoomCamera.tilted.face(of: shape, in: CGSize(width: 127, height: 104)))
            #expect(face.anchor.dx.isFinite && face.anchor.dy.isFinite)
            #expect(face.xScale.isFinite && face.yScale.isFinite && face.turn.isFinite)
        }
    }

    @Test("Ordinary room layouts retain finite projections across shapes and leans")
    func validLayouts() throws {
        let sizes = [CGSize(width: 127, height: 104), CGSize(width: 260, height: 84), CGSize(width: 1, height: 1)]
        for size in sizes {
            for shape in WorkerShape.allCases {
                for lean: Float in [0, 0.5, 1] {
                    let face = try #require(RoomCamera.tilted.face(of: shape, in: size, lean: lean))
                    #expect(face.anchor.dx.isFinite && face.anchor.dy.isFinite)
                    #expect(face.xScale.isFinite && face.yScale.isFinite && face.turn.isFinite)
                }
            }
        }
    }
}
