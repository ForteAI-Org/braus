//
//  HouseAwayPlaque+Metrics.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import simd

extension HouseAwayPlaque.PlaqueView {

    /// Metrics is the plaque's geometry in a room of a given size, in points from the room's top-left
    /// corner with y down.
    ///
    /// From above, the plate hangs flat from a nail over the worker's place, its shadow just below it.
    /// Through the tilted camera it hangs in the room where the worker stood, from two cords that rise
    /// out of the opening: a slab `thickness` deep whose face leans back `faceTilt` toward the camera,
    /// seen with the room's own perspective, so its lit top face shows above it and its shadow falls
    /// on the floor from the room's lamp. Its face leans back less than the camera looks down, which
    /// would show it square on, but enough that the text keeps at least 90% of its height.
    struct Metrics {

        /// The plaque's size against the one in a room whose short side is 104 points.
        let scale: CGFloat

        /// The plate's face in its own plane, before any perspective.
        let plate    : CGSize
        let showsText: Bool

        /// Where the plaque turns: the nail from above, or where its cords leave the opening. `top`
        /// is its distance below the room's top edge, `nailX` from its left edge, and `drop` the
        /// height from there to the plate's top.
        let top  : CGFloat
        let nailX: CGFloat
        let drop : CGFloat

        /// The plate's face as shown: its bottom-left, bottom-right, top-right and top-left corners.
        let face: [CGPoint]

        /// The slab's top as shown, the band between its upper outline at the face and at the back;
        /// nil from above, where it does not show.
        let rim: [CGPoint]?

        /// The cords as shown, each from the plate up.
        let cords: [[CGPoint]]

        /// The plate's shadow as it falls, and how soft it is; and where the light through the glass
        /// tints it, and how soft that is.
        let shadow    : [CGPoint]
        let shadowBlur: CGFloat
        let cast      : [CGPoint]
        let castBlur  : CGFloat

        /// How far the face leans back from upright toward the tilted camera, in radians.
        static let faceTilt = 25 * Double.pi / 180

        /// How deep the slab is behind its face, and the radius of its corners, in points at full
        /// scale.
        static let thickness   : CGFloat = 5
        static let cornerRadius: CGFloat = 7

        /// The least margin beside the text.
        static let textMargin: CGFloat = 5

        /// The least margin between the plate and the room's left wall in a room leaning left.
        static let wallMargin: CGFloat = 8

        /// The least scale that keeps the text on the plate, which below it has no height for it.
        static let textScale: CGFloat = 0.65

        /// The text's width at its 9 points.
        static let textWidth = NSAttributedString(
            string    : HouseAwayPlaque.text,
            attributes: [.font: HouseAwayPlaque.PlaqueView.font]
        ).size().width.rounded(.up)

        /// The plaque in a room of `room` points seen through `camera`, its composition leaning
        /// `lean`, over the worker's place. Leaning left, the plate keeps within the worker's place,
        /// clear of the left wall and of the name beside it, and centres on the room's height, where
        /// no name is under it.
        init(
            room  : CGSize,
            camera: RoomCamera = .top,
            lean  : Float = 0
        ) {
            let bodyX  = RoomLightUniforms.Shape.bodyX(
                in  : room,
                lean: lean
            )
            // Leaning, the worker's place reaches halfway from its body to the name beside it.
            let place  = CGFloat(RoomLightUniforms.Shape(
                size: room,
                lean: lean
            ).sphereRadius) + HouseLayout.nameGap / 2
            let widest = lean > 0 ? min(
                0.7 * room.width,
                2 * (bodyX - Self.wallMargin),
                2 * place
            ) : 0.7 * room.width
            let lined  = Self.textWidth + 2 * Self.textMargin
            scale     = max(0, min(1, min(room.width, room.height) / 104))
            showsText = lined <= widest && scale >= Self.textScale
            plate = CGSize(
                width : max(0, min(widest, showsText ? max(88 * scale, lined) : 88 * scale)),
                height: 30 * scale
            )
            // An empty room, as before its first layout, has no perspective to place the plate in.
            guard camera == .tilted, room.width > 0, room.height > 0 else {
                let drop = 9 * scale
                let top  = max(
                    4,
                    (room.height - CGFloat(1 - lean) * HouseLayout.nameBand - plate.height - drop) / 2
                )
                let face = CGRect(
                    x     : bodyX - plate.width / 2,
                    y     : top + drop,
                    width : plate.width,
                    height: plate.height
                )
                let inset = 16 * scale
                self.top   = top
                self.nailX = bodyX
                self.drop  = drop
                self.face  = Self.corners(of: face)
                rim        = nil
                cords      = [
                    [
                        CGPoint(
                            x: face.minX + inset,
                            y: face.minY
                        ),
                        CGPoint(
                            x: bodyX,
                            y: top + 1.5 * scale
                        ),
                        CGPoint(
                            x: face.maxX - inset,
                            y: face.minY
                        ),
                    ],
                ]
                // The lamp is above the plate, so its shadow falls just below it.
                shadow     = Self.corners(of: face.offsetBy(
                    dx: 0,
                    dy: 3 * scale
                ))
                shadowBlur = 4 * scale
                cast       = Self.corners(of: CGRect(
                    x     : face.minX + 0.1 * face.width,
                    y     : face.maxY - 0.35 * face.height + 4.5 * scale,
                    width : 0.8 * face.width,
                    height: 0.35 * face.height
                ))
                castBlur   = 3 * scale
                return
            }

            let view   = RoomCamera.Perspective(
                size: room,
                lean: lean
            )
            // The plate hangs where the window's centre plane passes over the worker's place, so it
            // shows at its own size, centred on the cell's height.
            let centre = SIMD3(
                view.bodyX,
                view.depth / 2,
                view.wallTop / 2
            )
            let size   = SIMD2(
                Double(plate.width),
                Double(plate.height)
            ) / view.scale(at: centre)
            let across = SIMD3<Double>(1, 0, 0)
            let up     = SIMD3(0, -sin(Self.faceTilt), cos(Self.faceTilt))
            let normal = SIMD3(0, cos(Self.faceTilt), sin(Self.faceTilt))
            let depth  = Double(Self.thickness * scale)
            func point(
                _ x: Double,
                _ y: Double
            ) -> SIMD3<Double> {
                centre + x * size.x / 2 * across + y * size.y / 2 * up
            }
            let corners = [
                point(-1, -1),
                point(1, -1),
                point(1, 1),
                point(-1, 1),
            ]
            face = corners.map(view.project)
            // The slab's upper outline at its face and at its back: between them its top face and the
            // tops of its rounded corners show.
            let flat    = plate
            let outline = Self.upperOutline(
                of    : flat,
                corner: Self.cornerRadius * scale
            ).map { point(2 * $0.x / flat.width - 1, 2 * $0.y / flat.height - 1) }
            rim = (outline + outline.reversed().map { $0 - depth * normal }).map(view.project)
            // The cords rise from the middle of the top face, through the opening's top edge.
            let rise  = SIMD3(0, 0, 3 * Double(room.height))
            let inset = min(Double(16 * scale), 0.3 * size.x)
            let hooks = [-1.0, 1.0].map { side in
                point(side * (1 - 2 * inset / size.x), 1) - depth / 2 * normal
            }
            cords = hooks.map { [view.project($0), view.project($0 + rise)] }
            let foot  = view.project(point(0, 1) - depth / 2 * normal)
            let head  = view.project(point(0, 1) - depth / 2 * normal + rise)
            // Where the line up from the plate's top crosses the room's top edge.
            let share = foot.y / max(foot.y - head.y, 1e-9)
            top   = 0
            nailX = foot.x + share * (head.x - foot.x)
            drop  = min(face[2].y, face[3].y)
            // The lamp hangs behind the plate and above it, so the plate's shadow falls on the floor
            // toward the camera, its penumbra wide like the worker's.
            let lamp   = view.lamp
            let fallen = corners.map { corner in
                corner + corner.z / max(lamp.z - corner.z, 1e-9) * (corner - lamp)
            }
            shadow     = fallen.map { view.project(SIMD3($0.x, $0.y, 0)) }
            shadowBlur = 4 * scale
            let middle = CGPoint(
                x: shadow.map(\.x).reduce(0, +) / 4,
                y: shadow.map(\.y).reduce(0, +) / 4
            )
            cast       = shadow.map { corner in
                CGPoint(
                    x: middle.x + 0.55 * (corner.x - middle.x),
                    y: middle.y + 0.55 * (corner.y - middle.y)
                )
            }
            castBlur   = 4 * scale
        }

        /// Points along the upper half of a plate of `plate` points with corners of radius `corner`,
        /// from the middle of its left side over its top to the middle of its right side, in the
        /// plate's own coordinates, its origin at its bottom-left corner and y up.
        private static func upperOutline(
            of plate: CGSize,
            corner  : CGFloat
        ) -> [CGPoint] {
            let radius = min(corner, plate.width / 2, plate.height / 2)
            let steps  = 6
            func arc(
                around centre: CGPoint,
                from start   : Double
            ) -> [CGPoint] {
                (0...steps).map { step in
                    let angle = start - Double(step) / Double(steps) * Double.pi / 2
                    return CGPoint(
                        x: centre.x + radius * cos(angle),
                        y: centre.y + radius * sin(angle)
                    )
                }
            }
            let left  = arc(
                around: CGPoint(
                    x: radius,
                    y: plate.height - radius
                ),
                from  : Double.pi
            )
            let right = arc(
                around: CGPoint(
                    x: plate.width - radius,
                    y: plate.height - radius
                ),
                from  : Double.pi / 2
            )
            return [CGPoint(
                x: 0,
                y: plate.height / 2
            )] + left + right + [CGPoint(
                x: plate.width,
                y: plate.height / 2
            )]
        }

        /// The corners of `rect` in the order `face` keeps: bottom-left, bottom-right, top-right and
        /// top-left, with y down.
        private static func corners(of rect: CGRect) -> [CGPoint] {
            [
                CGPoint(
                    x: rect.minX,
                    y: rect.maxY
                ),
                CGPoint(
                    x: rect.maxX,
                    y: rect.maxY
                ),
                CGPoint(
                    x: rect.maxX,
                    y: rect.minY
                ),
                CGPoint(
                    x: rect.minX,
                    y: rect.minY
                ),
            ]
        }

        /// The transform that takes a plate of `plate` points, its origin at its bottom-left corner
        /// and y up, onto `quad`, its bottom-left, bottom-right, top-right and top-left corners: the
        /// projective map of a square onto a quadrilateral, scaled to the plate. The layer it is given
        /// to has its anchor point and position at the origin. Identity for an empty plate.
        static func transform(
            mapping plate: CGSize,
            to quad      : [CGPoint]
        ) -> CATransform3D {
            guard plate.width > 0, plate.height > 0, quad.count == 4 else { return CATransform3DIdentity }
            let x  = quad.map { Double($0.x) }
            let y  = quad.map { Double($0.y) }
            let dx = (x[1] - x[2], x[3] - x[2], x[0] - x[1] + x[2] - x[3])
            let dy = (y[1] - y[2], y[3] - y[2], y[0] - y[1] + y[2] - y[3])
            let determinant = dx.0 * dy.1 - dx.1 * dy.0
            var g = 0.0
            var h = 0.0
            // A parallelogram maps affinely; any other quadrilateral needs the projective terms.
            if (dx.2 != 0 || dy.2 != 0), determinant != 0 {
                g = (dx.2 * dy.1 - dx.1 * dy.2) / determinant
                h = (dx.0 * dy.2 - dx.2 * dy.0) / determinant
            }
            let width  = Double(plate.width)
            let height = Double(plate.height)
            var matrix = CATransform3DIdentity
            matrix.m11 = (x[1] - x[0] + g * x[1]) / width
            matrix.m21 = (x[3] - x[0] + h * x[3]) / height
            matrix.m41 = x[0]
            matrix.m12 = (y[1] - y[0] + g * y[1]) / width
            matrix.m22 = (y[3] - y[0] + h * y[3]) / height
            matrix.m42 = y[0]
            matrix.m14 = g / width
            matrix.m24 = h / height
            return matrix
        }
    }
}
