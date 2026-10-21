//
//  RoomLight.metal
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

// A room seen straight from above, orthographic: a floor with a rounded outline, low walls that curve
// up from it as a cove, so their faces show from above, and the worker as a glossy body of dark
// graphite metal at the centre resting on the floor: its outline (`ShapeOutline` in Swift) grown
// into a rounded solid, the sphere for a circle. A soft disc lamp above the body, a little toward the
// top, lights the room in the worker's status colour; it casts an elliptical pool as wide as the room.
// Scene units are points: x to the right, y down as on screen, z up from the floor.
//
// Every kernel writes two linear images: `base`, the room without its worker's light, and `light`,
// the light alone with its bleed on the walls and its reflections on the body. `resolveRoom` adds
// them with a weight, tone maps once and writes sRGB, which lets the light pulse without rendering.
// `traceRoom` traces the scene against an acceleration structure; `precomputeRoom` evaluates the
// same scene analytically. `traceTiltedRoom` and `precomputeTiltedRoom` see a room with tall walls
// through the tilted camera instead, as the section on the tilted view below describes. Each kernel
// has a leaning twin (`traceLeaningRoom` and so on) for a room whose composition leans left, the
// rows': the worker stands larger at the left, the lamp hangs above it and a little further left, and
// the pool spreads from it toward the right; the tilted eye stands across from it.

#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace raytracing;

/// RoomLightUniforms matches `RoomLightUniforms.Packed` in Swift: seven float4, 112 bytes.
struct RoomLightUniforms {
    float4 light;     // sRGB colour, strength in w
    float4 outline;   // the body's core: sides, size, turn or offset, and corner radius, in sphere radii
    float4 body;      // dome height, lowest point and standing slab in sphere radii, w is 1 when occupied
    float4 room;      // width and height in points, points per pixel, the tilted room's cove radius
    float4 shape;     // wall height, wall reach, sphere radius, corner radius, in points
    float4 camera;    // the tilted view's floor depth, back wall top, focal length, worker's depth
    float4 stage;     // the worker's distance from the left wall in points, the composition's lean
};

// The lamp, a disc facing down, as fractions of the room's short side. Its size keeps every shadow
// soft.
constant float lampHeightShare = 0.7;
constant float lampRadiusShare = 0.32;

// The pool of light, after the prototype's radial-gradient(62% 78% at 50% 42%), which centres it on
// the prototype's sphere: centre and radii as fractions of the room's size, a soft core and a faint
// tail that reaches the walls. The lamp sits over the centre, a little toward the top.
constant float2 poolCentre = float2(0.5, 0.47);
constant float2 poolRadii  = float2(0.62, 0.78);
constant float  poolCore   = 0.32;   // in a wide room
constant float  tileCore   = 0.27;   // in a tile about as tall as wide, as casa's small rooms
constant float  tileGain   = 1.3;    // the tile's narrower core, as bright where it shows
constant float  poolTail   = 0.005;
constant float  tailWidth  = 1.1;
constant float  wallCatch  = 13;

// The pool of a room leaning left, as fractions of the room's short side around the worker: a
// core as tall as the floor plan's, short toward the left wall and long toward the right, and a wash
// that carries on right, widening as it goes and fading slowly, so the light dies into the room's
// dark right side with no edge. The lamp hangs `lampLead` left of the worker.
constant float lampLead       = 0.15;
constant float leanCoreLeft   = 0.42;
constant float leanCoreRight  = 0.75;
constant float leanCoreHeight = 0.3;
constant float leanWash       = 0.25;   // the wash's share of the pool at its centre
constant float leanWashReach  = 1.3;    // how far right the wash falls to 1/e
constant float leanWashSpread = 0.35;   // how much taller it grows for each short side it travels
constant float2 leanTailReach = float2(1.8, 0.8);   // the walls' faint lit rim, rightward and across

// Where a room leaning left goes dark, in short sides right of the worker: from `darkFrom` its light
// fades, and from `darkTo` on its floor and walls are black, light and ambient alike, so the right
// end shows no lit wall, corner or edge. `RoomLightUniforms.Shape.rightDark` holds the same range for
// the light the room spills onto the column.
constant float darkFrom = 1.0;
constant float darkTo   = 2.3;

constant float  floorAlbedo = 0.5;
constant float  wallAlbedo  = 0.7;
constant float  exposure    = 0.42;
constant float3 ambient     = float3(0.003);  // #0A0A0A, the unlit room

// The lamp's radiance seen in a reflection, against the light it gives the floor under it, and the
// bright core of its disc that the metal mirrors, as a share of its radius.
constant float lampGlow      = 1.8;
constant float lampCoreShare = 1.0;

// The body's graphite metal: GGX roughness, how much it reflects head on, neutral, the shares of the
// room the precomputed path shows on it, and how much of the painted body's own light a metal keeps.
constant float metalRoughness   = 0.24;
constant float metalReflectance = 0.75;
constant float sheenShare       = 0.2;   // the precomputed estimate of the floor on the metal
constant float rimShare         = 0.6;   // the precomputed estimate of the walls at the silhouette
constant float bodyDiffuse      = 0.6;

// The metal reflects for the room's camera, straight down: its top looks up at the lamp, its
// silhouette sideways into the walls, the ring between down onto the floor beside it.
constant float3 bodyView = float3(0, 0, 1);

// Where the metal sees the lamp's glow, from the lamp, as fractions of the room's short side: north-
// west and a little lower, so the soft reflection sits upper left, as MascotLayer's sheen does.
// Moving the lamp itself there threw a long hard shadow across the room, so only the reflection
// takes this offset, as MascotLayer's sheen follows a key light of its own.
constant float3 glowOffset = float3(-0.45, -0.6, -0.25);

// Points on the lamp the precomputed shadow tests, on the floor and walls seen directly, and where
// it estimates bounces and the room's sheen on the body.
constant uint occlusionSamples  = 32;
constant uint reflectionSamples = 6;

// Ray-traced sampling: frames accumulated per change, shadow rays per frame, ambient occlusion reach.
constant uint  accumulatedFrames = 64;
constant uint  shadowRays        = 2;
constant uint  glossRays         = 4;     // reflection rays per frame on the body
constant float backdropRise      = 3;     // how high the walls seem to rise in the metal
constant float backdropGlow      = 3;     // how much more light the risen walls catch
constant float occlusionReach    = 0.25;  // of the short side
// The share of the lamp's light that ambient occlusion also takes, in corners and at walls' foot.
constant float occlusionLightShare = 0.35;

// Geometry ids in the acceleration structure: the room is 0.
constant uint bodyGeometry = 1;

struct Room {
    float2 size;
    float  side;
    float  wallHeight;
    float  wallReach;
    float  cornerRadius;
    float3 body;         // the centre of the body's outline at its equator, a corner radius up
    float  radius;       // the sphere's, whose area every outline has
    uint   coreSides;    // 0 for a segment, 2 for a lens, else a regular polygon's sides
    float  coreSize;     // the polygon's vertex radius, the segment's half length, the lens's radius
    float  coreTurn;     // the polygon's first vertex angle
    float  coreOffset;   // the lens's circles' offset from its axis
    float  bodyCorner;   // the bevel's radius, every corner's
    float  bodyDome;
    float  bodyBottom;   // how far the outline reaches below its centre, in sphere radii
    float  bodySlab;     // standing, how far the core is thickened before and behind its middle
    float  lean;         // 0 with the worker at the centre, 1 at the left
    float2 poolCentre;   // where the pool centres once the composition leans, across on the worker
    float3 lamp;
    float  lampRadius;
    float3 light;        // linear colour times strength and exposure
    float3 lightSRGB;
    float  strength;
    float3 metal;        // linear reflectance of the body head on
    bool   isOccupied;
    float  pointsPerPixel;
    bool   isTilted;     // seen through the tilted camera, whose room has the fields below
    float  depth;        // how far the floor's front edge, the window's foot, is from the back wall
    float  fillet;       // the radius of the coves where the walls meet the floor
    float2 footprint;    // the walls' rounded outline, from the back wall far past the window
};

struct Surface {
    float3 position;
    float3 normal;
    float  albedo;
};

/// Images is one sample of a pixel: what belongs to the base image and what to the light image.
struct Images {
    float3 base;
    float3 light;
};

static float square(float x) { return x * x; }

static float3 linearFromSRGB(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float3 sRGBFromLinear(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

/// Keeps radiance up to 0.5 as it is, so the authored body keeps its colours, and rolls the rest
/// off smoothly toward 1.
static float3 toneMap(float3 radiance) {
    float3 over = max(radiance - 0.5, 0.0);
    return min(radiance, 0.5) + 0.5 * (1 - exp(-over / 0.5));
}

/// The pixel's final colour: `linear` in sRGB with half a step of noise, so the dark gradients do
/// not show 8-bit bands.
static float4 encodedPixel(float3 linear, uint2 pixel) {
    float noise = fract(52.9829189 * fract(dot(float2(pixel), float2(0.06711056, 0.00583715))));
    return float4(sRGBFromLinear(linear) + (noise - 0.5) / 255, 1);
}

/// Moves `room`'s worker to where the stage puts it across the room, and its lamp `lampLead` further
/// left, as far as the composition leans; the pool centres across on the worker, as far from the
/// back as the floor plan's.
static void leanLeft(thread Room& room, constant RoomLightUniforms& uniforms) {
    room.body.x     = uniforms.stage.x;
    room.lamp.x     = room.body.x - lampLead * room.side * room.lean;
    room.poolCentre = float2(room.body.x, poolCentre.y * room.size.y);
}

static Room makeRoom(constant RoomLightUniforms& uniforms) {
    Room room;
    room.size           = uniforms.room.xy;
    room.side           = min(room.size.x, room.size.y);
    room.wallHeight     = uniforms.shape.x;
    room.wallReach      = uniforms.shape.y;
    room.radius         = uniforms.shape.z;
    room.cornerRadius   = uniforms.shape.w;
    room.coreSides      = uint(uniforms.outline.x + 0.5);
    room.coreSize       = uniforms.outline.y * room.radius;
    room.coreTurn       = uniforms.outline.z;
    room.coreOffset     = uniforms.outline.z * room.radius;
    room.bodyCorner     = uniforms.outline.w * room.radius;
    room.bodyDome       = uniforms.body.x * room.radius;
    room.bodyBottom     = uniforms.body.y;
    room.body           = float3(room.size * 0.5, room.bodyCorner);
    room.lamp           = float3(poolCentre * room.size, lampHeightShare * room.side);
    room.lampRadius     = lampRadiusShare * room.side;
    room.strength       = uniforms.light.w;
    room.lightSRGB      = uniforms.light.rgb;
    room.light          = linearFromSRGB(uniforms.light.rgb) * uniforms.light.w * exposure;
    room.metal          = float3(metalReflectance);
    room.isOccupied     = uniforms.body.w > 0.5;
    room.pointsPerPixel = uniforms.room.z;
    room.isTilted       = false;
    room.depth          = 0;
    room.fillet         = 0;
    room.footprint      = room.size;
    room.bodySlab       = 0;
    room.lean           = 0;
    return room;
}

/// The room as its composition stands it: the floor plan's, or, when it `leans`, moved left as far as
/// the stage says. A template, so the floor plan's kernels compile with no lean at all and render
/// exactly as they did before the rows leaned.
template <bool leans>
static Room stagedRoom(constant RoomLightUniforms& uniforms) {
    Room room = makeRoom(uniforms);
    if (leans) {
        room.lean = uniforms.stage.y;
        leanLeft(room, uniforms);
    }
    return room;
}

// MARK: - The room

/// The distance from `xy` in to the room's rounded outline, negative outside, and in `inward` the
/// direction that points into the room.
static float insideDistance(float2 xy, Room room, thread float2& inward) {
    float2 p    = xy - room.size * 0.5;
    float2 sign = select(float2(1), float2(-1), p < 0);
    float  r    = room.cornerRadius;
    float2 q    = abs(p) - room.size * 0.5 + r;
    if (q.x > 0 && q.y > 0) {
        float length = max(metal::length(q), 1e-4);
        inward = -q / length * sign;
        return r - length;
    }
    inward = q.x > q.y ? float2(-sign.x, 0) : float2(0, -sign.y);
    return r - max(q.x, q.y);
}

/// The floor or wall seen from above at `xy`. A wall rises as a cove, z = height × t², where t
/// grows from 0 at its foot to 1 at the outline: its normal turns from the floor's smoothly, so
/// no groove marks the foot, and its albedo blends the same way.
static Surface surfaceAt(float2 xy, Room room) {
    float2 inward;
    float  edge  = max(insideDistance(xy, room, inward), 0.0);
    float  t     = saturate(1 - edge / room.wallReach);
    float  slope = 2 * room.wallHeight * t / room.wallReach;
    Surface surface;
    surface.position = float3(xy, room.wallHeight * t * t);
    surface.normal   = normalize(float3(inward * slope, 1));
    surface.albedo   = mix(floorAlbedo, wallAlbedo, t);
    return surface;
}

/// The floor plan's pool around `centre`, 1 there, as `pool` lays it around the room's centre.
static float centredPool(float2 xy, float2 centre, float wallShare, Room room) {
    float distance = length((xy - centre) / (poolRadii * room.size));
    float tail     = poolTail * (1 + wallCatch * wallShare);
    float wide     = saturate((room.size.x / room.size.y - 1.3) / 0.7);
    float core     = mix(tileCore, poolCore, wide);
    float gain     = mix(tileGain, 1.0, wide);
    return (1 - poolTail) * gain * exp(-square(distance / core)) + tail * exp(-square(distance / tailWidth));
}

/// How much of its light a point `right` short sides right of the worker keeps in a room leaning
/// fully left: all of it up to `darkFrom`, none from `darkTo`.
static float rightFade(float right) {
    return 1 - smoothstep(darkFrom, darkTo, right);
}

/// How much of its light and ambient a floor or wall point at `x` keeps in a room leaning left, as
/// far as it leans: less toward the right end, which is black.
static float rightDarkness(float x, Room room) {
    return mix(1.0, rightFade((x - room.body.x) / room.side), saturate(room.lean));
}

/// `images` of a floor or wall point at `x`, darkened toward the right end when the room `leans`;
/// the bounced light and the ambient there go dark with the lamp's.
template <bool leans>
static Images darkenedRight(Images images, float x, Room room) {
    if (!leans) { return images; }
    float keep = rightDarkness(x, room);
    return { images.base * keep, images.light * keep };
}

/// The pool of a room leaning fully left, 1 at its centre: the core and the rightward wash, and
/// the walls' lit rim, fading toward the right as the floor does and gone by `darkTo`.
static float leaningPool(float2 xy, float wallShare, Room room) {
    float2 offset = (xy - room.poolCentre) / room.side;
    float  right  = max(offset.x, 0.0);
    float  across = offset.x / (offset.x > 0 ? leanCoreRight : leanCoreLeft);
    float  core   = exp(-square(across) - square(offset.y / leanCoreHeight));
    float  height = leanCoreHeight + leanWashSpread * right;
    float  wash   = exp(-right / leanWashReach - square(min(offset.x, 0.0) / leanCoreLeft) - square(offset.y / height))
                  * leanCoreHeight / height;
    float2 reach  = float2(offset.x > 0 ? leanTailReach.x : leanCoreLeft, leanTailReach.y);
    float  tail   = poolTail * (1 + wallCatch * wallShare) * exp(-square(length(offset / reach) / tailWidth));
    return ((1 - poolTail) * ((1 - leanWash) * core + leanWash * wash) + tail) * rightFade(offset.x);
}

/// The lamp's pool at a point of the room, 1 at its centre. The core falls off like the prototype's
/// gradient; the tail is the lamp's side light, which the walls catch `wallCatch` times more than
/// the floor, so they read as a lit rim. A room leaning left has the leaning pool, or a blend of the
/// two while it leans part of the way.
static float pool(float2 xy, float wallShare, Room room) {
    if (room.lean > 0) {
        float leaning = leaningPool(xy, wallShare, room);
        return room.lean >= 1 ? leaning : mix(centredPool(xy, room.poolCentre, wallShare, room), leaning, room.lean);
    }
    float distance = length((xy - poolCentre * room.size) / (poolRadii * room.size));
    float tail     = poolTail * (1 + wallCatch * wallShare);
    float wide     = saturate((room.size.x / room.size.y - 1.3) / 0.7);
    float core     = mix(tileCore, poolCore, wide);
    float gain     = mix(tileGain, 1.0, wide);
    return (1 - poolTail) * gain * exp(-square(distance / core)) + tail * exp(-square(distance / tailWidth));
}

/// The light a point of the lamp at `lampPoint` gives a surface, before its colour and albedo: the
/// pool, more on a wall that faces the lamp than on the floor.
static float lampTerm(float3 position, float3 normal, float3 lampPoint, Room room) {
    float3 direction = normalize(lampPoint - position);
    return pool(position.xy, 1 - normal.z, room) * max(dot(normal, direction), 0.0) / max(direction.z, 0.3);
}

// MARK: - The body

// The body is its core, a flat convex figure at its equator, grown by a ball of `bodyCorner`
// radius: flanks with a quarter-circle bevel all round, and a gentle dome over the outline.

/// Sector is the polygon core's frame at a point: the point turned so the side of its sector faces
/// along x and folded to positive y, with the turn and the fold that undo it.
struct Sector {
    float2 local;
    float  angle;   // the side's normal
    float  fold;    // -1 when y was folded
};

static Sector polygonSector(float2 p, Room room) {
    float  sector = 2 * M_PI_F / room.coreSides;
    float  angle  = atan2(p.y, p.x) - room.coreTurn - 0.5 * sector;
    float  turn   = angle - round(angle / sector) * sector;
    Sector frame;
    frame.local = length(p) * float2(cos(turn), abs(sin(turn)));
    frame.angle = atan2(p.y, p.x) - turn;
    frame.fold  = turn < 0 ? -1 : 1;
    return frame;
}

/// A vector of `frame` back in the room.
static float2 unfold(float2 v, Sector frame) {
    v.y *= frame.fold;
    float2 axis = float2(cos(frame.angle), sin(frame.angle));
    return float2(axis.x * v.x - axis.y * v.y, axis.y * v.x + axis.x * v.y);
}

/// The point of the body's core nearest `xy`, or `xy` itself inside the core.
static float2 corePoint(float2 xy, Room room) {
    float2 p = xy - room.body.xy;
    if (room.coreSides >= 3) {
        Sector frame    = polygonSector(p, room);
        float  halfTurn = M_PI_F / room.coreSides;
        float  inner    = room.coreSize * cos(halfTurn);
        if (frame.local.x <= inner) { return xy; }
        return room.body.xy + unfold(float2(inner, min(frame.local.y, room.coreSize * sin(halfTurn))), frame);
    }
    if (room.coreSides == 2) {
        float2 sides  = select(float2(1), float2(-1), p < 0);
        float2 folded = abs(p);
        float2 centre = float2(0, -room.coreOffset);
        float  tip    = sqrt(square(room.coreSize) - square(room.coreOffset));
        if (length(folded - centre) <= room.coreSize) { return xy; }
        // On the arc where it faces `folded`, else at the tip.
        bool   onArc   = (folded.y + room.coreOffset) * tip > folded.x * room.coreOffset;
        float2 nearest = onArc ? centre + room.coreSize * normalize(folded - centre) : float2(tip, 0);
        return room.body.xy + nearest * sides;
    }
    return room.body.xy + float2(clamp(p.x, -room.coreSize, room.coreSize), 0);
}

/// How far `xy` lies outside the body's outline; inside, at most minus the corner radius.
static float outlineDistance(float2 xy, Room room) {
    return length(xy - corePoint(xy, room)) - room.bodyCorner;
}

/// How far along the unit `ray` from the origin it leaves the circle of `radius` around `centre`.
static float circleExit(float2 ray, float2 centre, float radius) {
    float along = dot(ray, centre);
    return along + sqrt(max(along * along - dot(centre, centre) + radius * radius, 0.0));
}

/// The outline's gauge at `xy` in `x`: 0 at the body's centre, 1 on the outline, growing along every
/// ray as the share of the way out; in `yz` its gradient: the outline's normal where the ray through
/// `xy` leaves it, divided by its dot product with that exit point.
static float3 outlineGauge(float2 xy, Room room) {
    float2 p        = xy - room.body.xy;
    float  distance = length(p);
    if (distance < 1e-4 * room.radius) { return float3(0); }
    float  corner = room.bodyCorner;
    float  reach;
    float2 normal;
    if (room.coreSides >= 3) {
        Sector frame    = polygonSector(p, room);
        float2 ray      = frame.local / distance;
        float  halfTurn = M_PI_F / room.coreSides;
        float2 tip      = room.coreSize * float2(cos(halfTurn), sin(halfTurn));
        // Through the straight side, or past it through the corner's arc.
        if ((tip.x + corner) * ray.y <= tip.y * ray.x) {
            reach  = (tip.x + corner) / ray.x;
            normal = float2(1, 0);
        } else {
            reach  = circleExit(ray, tip, corner);
            normal = reach * ray - tip;
        }
        float2 gradient = normal / dot(normal, reach * ray);
        return float3(distance / reach, unfold(gradient, frame));
    }
    float2 sides = select(float2(1), float2(-1), p < 0);
    float2 ray   = abs(p) / distance;
    if (room.coreSides == 2) {
        float2 centre = float2(0, -room.coreOffset);
        float  tip    = sqrt(square(room.coreSize) - square(room.coreOffset));
        reach  = circleExit(ray, centre, room.coreSize + corner);
        normal = reach * ray - centre;
        if ((reach * ray.y + room.coreOffset) * tip < reach * ray.x * room.coreOffset) {
            reach  = circleExit(ray, float2(tip, 0), corner);
            normal = reach * ray - float2(tip, 0);
        }
    } else if (corner * ray.x <= room.coreSize * ray.y) {
        reach  = corner / ray.y;
        normal = float2(0, 1);
    } else {
        reach  = circleExit(ray, float2(room.coreSize, 0), corner);
        normal = reach * ray - float2(room.coreSize, 0);
    }
    return float3(distance / reach, sides * normal / dot(normal, reach * ray));
}

/// BodyPoint is the body's top seen from above at a point: where it is and which way it faces.
struct BodyPoint {
    float3 position;
    float3 normal;
};

/// The body's top over `xy`: the bevel rises from the outline as a quarter circle of the corner
/// radius, flat over the core, and the dome adds `bodyDome` times one minus the gauge squared.
/// The normal points from the core at the equator to the bevel, tilted by the dome; for the
/// circle's point core it is the sphere's.
static BodyPoint bodyAt(float2 xy, Room room) {
    float2 outward = xy - corePoint(xy, room);
    outward       *= min(1.0, room.bodyCorner / max(length(outward), 1e-6));
    float  rise    = sqrt(max(square(room.bodyCorner) - dot(outward, outward), 0.0));
    float3 gauge   = room.bodyDome > 0 ? outlineGauge(xy, room) : float3(0);
    BodyPoint point;
    point.normal   = normalize(float3(outward + 2 * room.bodyDome * gauge.x * gauge.yz * rise, rise));
    point.position = float3(xy, room.body.z + rise + room.bodyDome * (1 - square(gauge.x)));
    return point;
}

/// The point of the body's core nearest `position`, the body being that core grown by the corner's
/// ball: from above the flat core at the equator; standing in the tilted view, the core upright in the
/// plane facing the camera and thickened by the slab before and behind it.
static float3 nearestCore(float3 position, Room room) {
    if (room.isTilted) {
        float2 core = corePoint(float2(position.x, room.body.y + room.body.z - position.z), room);
        float  away = clamp(position.y - room.body.y, -room.bodySlab, room.bodySlab);
        return float3(core.x, room.body.y + away, room.body.y + room.body.z - core.y);
    }
    return float3(corePoint(position.xy, room), room.body.z);
}

/// How far the segment from `start` along `line` passes outside the body, negative through it,
/// measured without the dome: the closest points of the segment and the core, found by projecting
/// each onto the other in turn. Exact at once for the circle's point core.
static float bodyMiss(float3 start, float3 line, Room room) {
    // ponytail: for flat cores three projections give an upper bound; iterate on if shadows look short.
    float3 core = room.body;
    float3 near = start;
    for (uint step = 0; step < 3; step++) {
        near = start + line * saturate(dot(core - start, line) / dot(line, line));
        core = nearestCore(near, room);
    }
    return length(near - core) - room.bodyCorner;
}

/// The share of the lamp the body hides from `position`, over a spiral of points on the lamp's
/// disc: each counts as hidden by how deep its line to `position` passes inside the body, softened
/// over a tenth of the sphere's radius, so the penumbra has no steps.
static float bodyOcclusion(float3 position, uint samples, Room room) {
    if (!room.isOccupied) { return 0; }
    float hidden = 0;
    for (uint index = 0; index < samples; index++) {
        float  radius    = room.lampRadius * sqrt((index + 0.5) / samples);
        float  angle     = 2 * M_PI_F * fract(index * 0.618034);
        float3 lampPoint = room.lamp + float3(radius * cos(angle), radius * sin(angle), 0);
        float  miss      = bodyMiss(position, lampPoint - position, room);
        hidden += 1 - smoothstep(-0.1 * room.radius, 0.1 * room.radius, miss);
    }
    return hidden / samples;
}

/// The sky the body hides from a floor or wall point, for the ambient light: as much as a sphere
/// hides whose surface is as far, toward the body's nearest core point.
static float bodyAmbientOcclusion(Surface surface, Room room) {
    if (!room.isOccupied) { return 0; }
    float3 toCore   = nearestCore(surface.position, room) - surface.position;
    float  distance = length(toCore);
    float  apart    = distance - room.bodyCorner + room.radius;
    return saturate(dot(surface.normal, toCore / distance)) * square(room.radius / max(apart, room.radius));
}

// MARK: - The body's paint, after MascotLayer

static float3 hexColor(uint hex) {
    return float3((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF) / 255.0;
}

/// Where `uv` falls in a radial gradient centred at `centre` with radii `radii`, all in the
/// sphere's unit square.
static float gradientPosition(float2 uv, float2 centre, float2 radii) {
    return length((uv - centre) / radii);
}

static float stops3(float t, float3 at, float3 values) {
    if (t <= at.x) { return values.x; }
    if (t <= at.y) { return mix(values.x, values.y, (t - at.x) / (at.y - at.x)); }
    if (t <= at.z) { return mix(values.y, values.z, (t - at.y) / (at.z - at.y)); }
    return values.z;
}

/// The body's own paint in linear light at `uv`, the sphere's unit square with y down, layered as
/// MascotLayer layers it: the graphite radial base, #1B1B1E at its lightest once dimmed, and the
/// darker lower half, with no painted highlight, since the lamp's reflection is the body's only one.
/// A worker that is off is dimmed. It belongs to the base image: it never pulses.
static float3 bodyPaint(float2 uv, Room room) {
    bool   isOff = room.strength <= 0;
    float  t     = gradientPosition(uv, float2(0.37, 0.30), float2(0.942));
    float3 color = t <= 0.44 ? mix(hexColor(0x2D2D32), hexColor(0x222226), t / 0.44)
                             : mix(hexColor(0x222226), hexColor(0x1F1F23), saturate((t - 0.44) / 0.56));
    // Metal has little diffuse light of its own: the painted body is dimmed, the reflections carry it.
    color *= bodyDiffuse;
    // The darker lower half, lighter at the edge than MascotLayer's, so the rim reads lit by the room.
    float shade = stops3(gradientPosition(uv, float2(0.5, 0.25), float2(0.85)), float3(0.55, 0.775, 1), float3(0, 0.12, 0.2));
    color = mix(color, float3(0), shade);
    return linearFromSRGB(isOff ? color * 0.45 : color);
}

/// The crescent of room light inside the bottom of the outline, MascotLayer's bounce, wide and faint
/// with a long soft falloff, raised with the outline's lowest point.
static float3 bodyBounce(float2 uv, Room room) {
    float2 centre = float2(0.5, 1.2 + 0.5 * (room.bodyBottom - 1));
    float  alpha  = 0.1 * exp(-square(gradientPosition(uv, centre, float2(1.4, 0.9)) / 0.4));
    return alpha * linearFromSRGB(room.lightSRGB) * room.strength;
}

/// The metal's reflectance at `cosine` between the facet and the viewer: its own head on, white at
/// grazing angles.
static float3 metalFresnel(float cosine, Room room) {
    return room.metal + (1 - room.metal) * pow(1 - saturate(cosine), 5.0);
}

/// The unit square coordinate of a point seen from above, in the sphere's bounding square around
/// the body's centre.
static float2 bodyUV(float2 xy, Room room) {
    return (xy - (room.body.xy - room.radius)) / (2 * room.radius);
}

// MARK: - Sampling

/// Two directions across `normal`.
static void basis(float3 normal, thread float3& tangent, thread float3& other) {
    float3 helper = abs(normal.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0);
    tangent = normalize(cross(helper, normal));
    other   = cross(normal, tangent);
}

/// A microfacet normal around `normal`, GGX distributed for `roughness`.
static float3 facetSample(float3 normal, float roughness, float2 sample) {
    float3 tangent, other;
    basis(normal, tangent, other);
    float cosine = sqrt((1 - sample.x) / (1 + (roughness * roughness - 1) * sample.x));
    float sine   = sqrt(max(0.0, 1 - cosine * cosine));
    float angle  = 2 * M_PI_F * sample.y;
    return normalize(tangent * sine * cos(angle) + other * sine * sin(angle) + normal * cosine);
}

/// The lamp mirrored by the body's metal at `point` toward `view`: the lamp's soft core seen through
/// the metal's gloss, a lobe around the mirror direction as wide as the two together, so the
/// highlight is smooth at any size. Nothing stands between the body and the lamp above it, so both paths
/// evaluate it the same way, without tracing.
static float3 lampHighlight(BodyPoint point, float3 view, Room room) {
    float3 normal   = point.normal;
    float3 toLamp   = room.lamp + glowOffset * room.side - point.position;
    float  distance = length(toLamp);
    float3 mirrored = reflect(-view, normal);
    float  apart    = acos(clamp(dot(mirrored, toLamp / distance), -1.0, 1.0));
    float  core     = atan(lampCoreShare * room.lampRadius / distance);
    float  gloss    = 1.2 * metalRoughness;
    float  spread   = core * core + gloss * gloss;
    float  facing   = saturate(4 * dot(normal, toLamp / distance));
    float3 halfway  = normalize(view + toLamp / distance);
    return lampGlow * room.light * (core * core / spread) * exp(-apart * apart / spread)
         * metalFresnel(dot(halfway, view), room) * facing;
}

/// The lamp mirrored by the body at `point` for the room's camera straight down.
static float3 lampHighlight(BodyPoint point, Room room) {
    return lampHighlight(point, bodyView, room);
}

// MARK: - Precomputed light

/// The light alone at a floor or wall point: the lamp with an analytic soft shadow tested against
/// `samples` points of the lamp, and the light floor and walls bounce to each other, estimated where
/// the nearest wall meets the floor.
static float3 analyticLight(float2 xy, uint samples, Room room) {
    Surface surface = surfaceAt(xy, room);
    float3  direct  = surface.albedo * lampTerm(surface.position, surface.normal, room.lamp, room)
                    * (1 - bodyOcclusion(surface.position, samples, room)) * room.light;

    float2 inward;
    float  edge = max(insideDistance(xy, room, inward), 0.0);
    float2 foot = xy + inward * (room.wallReach - edge);
    float  rise = saturate(1 - edge / room.wallReach);

    // The wall's middle, which lights the floor in front of it.
    Surface wall  = surfaceAt(foot - inward * room.wallReach * 0.5, room);
    float   fromWall = wall.albedo * lampTerm(wall.position, wall.normal, room.lamp, room)
                     * exp(-max(edge - room.wallReach, 0.0) / (0.08 * room.side));
    // The floor at the wall's foot, which lights the wall above it.
    Surface floor = surfaceAt(foot + inward * 0.5, room);
    float   fromFloor = floor.albedo * lampTerm(floor.position, floor.normal, room.lamp, room)
                      * (1 - bodyOcclusion(floor.position, reflectionSamples, room)) * rise;
    return direct + surface.albedo * (0.08 * fromWall + 0.45 * fromFloor) * room.light;
}

/// The room's light on the body's metal at `xy`, estimated without tracing, for the camera straight
/// down: the ring between the top and the silhouette sees the floor beside the body, the silhouette
/// the wall in the same direction, each as a smooth wash of the light found there, weakened by
/// `sheenShare` and `rimShare`. The ray tracer reflects the room itself instead.
static float3 roomSheen(float2 xy, float3 normal, Room room) {
    float  across   = length(normal.xy);
    float2 outward  = normal.xy / max(across, 1e-4);
    // Looking out from the core, which for the sphere is its centre.
    float2 from     = corePoint(xy, room);
    float2 toEdges  = select(from, room.size - from, outward > 0) / max(abs(outward), 1e-4);
    float  toWall   = min(toEdges.x, toEdges.y) - 0.5 * room.wallReach;
    float3 wall     = analyticLight(from + outward * toWall, reflectionSamples, room);
    float3 floor    = analyticLight(from + outward * (room.bodyCorner + 0.8 * room.radius), reflectionSamples, room);
    float  ring     = smoothstep(0.55, 0.85, across) * (1 - smoothstep(0.8, 1.0, across));
    float  rim      = smoothstep(0.75, 1.0, across);
    return metalFresnel(normal.z, room) * (ring * floor * sheenShare + rim * wall * rimShare);
}

/// One pixel of `precomputeRoom`, or of `precomputeLeaningRoom` when the room `leans`.
template <bool leans>
static void precomputeRoomAt(texture2d<float, access::write> base,
                             texture2d<float, access::write> light,
                             constant RoomLightUniforms&     uniforms,
                             uint2                           pixel)
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room    room    = stagedRoom<leans>(uniforms);
    float2  xy      = (float2(pixel) + 0.5) * room.pointsPerPixel;
    Surface surface = surfaceAt(xy, room);
    Images  images  = { ambient * (1 - bodyAmbientOcclusion(surface, room)), analyticLight(xy, occlusionSamples, room) };
    images = darkenedRight<leans>(images, xy.x, room);

    if (room.isOccupied) {
        float coverage = saturate(-outlineDistance(xy, room) / room.pointsPerPixel + 0.5);
        if (coverage > 0) {
            float2    uv        = bodyUV(xy, room);
            BodyPoint point     = bodyAt(xy, room);
            float3    reflected = roomSheen(xy, point.normal, room) + lampHighlight(point, room);
            images.base  = mix(images.base, bodyPaint(uv, room), coverage);
            images.light = mix(images.light, reflected + bodyBounce(uv, room), coverage);
        }
    }
    base.write(float4(images.base, 1), pixel);
    light.write(float4(images.light, 1), pixel);
}

kernel void precomputeRoom(texture2d<float, access::write> base     [[texture(0)]],
                           texture2d<float, access::write> light    [[texture(1)]],
                           constant RoomLightUniforms&     uniforms [[buffer(0)]],
                           uint2                           pixel    [[thread_position_in_grid]])
{
    precomputeRoomAt<false>(base, light, uniforms, pixel);
}

/// `precomputeRoom` for a room leaning left.
kernel void precomputeLeaningRoom(texture2d<float, access::write> base     [[texture(0)]],
                                  texture2d<float, access::write> light    [[texture(1)]],
                                  constant RoomLightUniforms&     uniforms [[buffer(0)]],
                                  uint2                           pixel    [[thread_position_in_grid]])
{
    precomputeRoomAt<true>(base, light, uniforms, pixel);
}

// MARK: - Resolve

kernel void resolveRoom(texture2d<float, access::read>  base   [[texture(0)]],
                        texture2d<float, access::read>  light  [[texture(1)]],
                        texture2d<float, access::write> output [[texture(2)]],
                        constant float&                 weight [[buffer(0)]],
                        uint2                           pixel  [[thread_position_in_grid]])
{
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) { return; }
    // An output wider than the room repeats the room's edge, as Core Animation does past an image.
    uint2  source   = min(pixel, uint2(base.get_width(), base.get_height()) - 1);
    float3 radiance = base.read(source).rgb + weight * light.read(source).rgb;
    output.write(encodedPixel(toneMap(radiance), pixel), pixel);
}

// MARK: - Ray-traced light

static uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static float random(thread uint& seed) {
    seed = pcg(seed);
    return float(seed) / 4294967296.0;
}

/// A point of the lamp's disc for `sample` in 0...1 squared.
static float3 lampSample(Room room, float2 sample) {
    float radius = room.lampRadius * sqrt(sample.x);
    float angle  = 2 * M_PI_F * sample.y;
    return room.lamp + float3(radius * cos(angle), radius * sin(angle), 0);
}

/// A direction around `normal`, cosine weighted, for `sample` in 0...1 squared.
static float3 cosineSample(float3 normal, float2 sample) {
    float3 tangent, other;
    basis(normal, tangent, other);
    float radius = sqrt(sample.x);
    float angle  = 2 * M_PI_F * sample.y;
    return normalize(tangent * radius * cos(angle) + other * radius * sin(angle) + normal * sqrt(max(0.0, 1 - sample.x)));
}

static intersector<> makeIntersector() {
    intersector<> rays;
    rays.assume_geometry_type(geometry_type::triangle);
    rays.force_opacity(forced_opacity::opaque);
    return rays;
}

/// Whether nothing stands between `position` and `lampPoint`.
static bool sees(float3 position, float3 normal, float3 lampPoint, primitive_acceleration_structure scene, Room room) {
    float3 start  = position + normal * room.side * 1e-3;
    float3 toLamp = lampPoint - start;
    float  span   = length(toLamp);
    intersector<> shadows = makeIntersector();
    shadows.accept_any_intersection(true);
    return shadows.intersect(ray(start, toLamp / span, 0, span), scene).type == intersection_type::none;
}

static Surface tiltedSurfaceAt(float3 position, Room room);

/// The floor or wall a ray hit, or false for the body or nothing.
static bool hitRoom(intersection_result<> hit, ray traced, Room room, thread Surface& surface) {
    if (hit.type == intersection_type::none || hit.geometry_id == bodyGeometry) { return false; }
    float3 position = traced.origin + traced.direction * hit.distance;
    surface = room.isTilted ? tiltedSurfaceAt(position, room) : surfaceAt(position.xy, room);
    surface.position = position;
    return true;
}

/// Frame is one of the accumulated frames of a pixel: its index, and the pixel's own rotation of
/// the sample patterns, so neighbouring pixels do not repeat each other's noise.
struct Frame {
    uint   index;
    float2 rotation;
};

/// The share of the lamp a floor or wall point sees through `count` shadow rays. Across the frames
/// the rays cover the disc as a spiral.
static float tracedLamp(Surface surface, uint count, primitive_acceleration_structure scene, Room room, Frame frame) {
    float samples = accumulatedFrames * count;
    float total   = 0;
    for (uint index = 0; index < count; index++) {
        float  number    = frame.index * count + index;
        float2 sample    = float2((number + 0.5) / samples, fract(number * 0.618034 + frame.rotation.x));
        float3 lampPoint = lampSample(room, sample);
        if (sees(surface.position, surface.normal, lampPoint, scene, room)) {
            total += lampTerm(surface.position, surface.normal, lampPoint, room);
        }
    }
    return total / count;
}

/// One frame of a floor or wall point: its ambient light, occluded by what stands near it, and
/// the lamp's light with soft shadows and one bounce.
static Images tracedRoom(Surface surface, primitive_acceleration_structure scene, Room room, Frame frame, thread uint& seed) {
    Images images;
    images.light = surface.albedo * tracedLamp(surface, shadowRays, scene, room, frame) * room.light;

    float2 stratum = float2(frame.index % 8, frame.index / 8);
    float2 sample  = fract((stratum + float2(random(seed), random(seed))) / 8 + frame.rotation);
    ray    bounce(surface.position + surface.normal * room.side * 1e-3, cosineSample(surface.normal, sample));
    intersection_result<> hit = makeIntersector().intersect(bounce, scene);
    bool isOccluded = hit.type != intersection_type::none && hit.distance < occlusionReach * room.side;
    images.base = isOccluded ? float3(0) : ambient;
    // What stands close takes a little of the lamp's light too, in the corners and at the walls' foot.
    images.light *= isOccluded ? 1 - occlusionLightShare : 1;

    Surface other;
    if (hitRoom(hit, bounce, room, other)) {
        Frame single = { frame.index, frame.rotation.yx };
        images.light += surface.albedo * other.albedo * tracedLamp(other, 1, scene, room, single) * room.light;
    }
    return images;
}

/// How much more of the lamp's side light a wall catches at `height`, as the metal sees it: rising
/// toward the lamp, up to `backdropGlow` times what its foot catches.
static float reflectedWallGlow(float height, Room room) {
    return mix(1.0, backdropGlow, smoothstep(0.2, 1.5, height / room.wallHeight));
}

/// The walls' glow a reflection ray meets above their top. The walls are low beside the body, so
/// the metal sees them as rising on, brighter toward the lamp and fading out by `backdropRise` times
/// their height: the room's lit rim reflected on the body's flanks, as in a taller room.
static float3 wallsAbove(float3 origin, float3 direction, Room room) {
    float across = length(direction.xy);
    if (across < 1e-3) { return float3(0); }
    float  travelled = 0;
    float2 inward;
    for (uint step = 0; step < 12; step++) {
        float edge = insideDistance(origin.xy + direction.xy * travelled, room, inward);
        if (edge < 0.05) { break; }
        travelled += edge / across;
    }
    float3  hit  = origin + direction * travelled;
    float   rise = hit.z / room.wallHeight;
    Surface wall = surfaceAt(hit.xy + inward * 0.05 * room.wallReach, room);
    wall.position.z = hit.z;
    float fade = 1 - smoothstep(1.0, backdropRise, rise);
    return fade * reflectedWallGlow(hit.z, room) * wall.albedo * lampTerm(wall.position, wall.normal, room.lamp, room) * room.light;
}

/// One frame of the body under `xy`: its paint, the lamp mirrored by its metal, the room reflected
/// through `glossRays` traced GGX facets with their shadows, and the crescent of room light at the
/// bottom. The traced mesh lies inside the shaded top, so the rays never start inside it.
static Images tracedBody(float2 xy, primitive_acceleration_structure scene, Room room, Frame frame, thread uint& seed) {
    float2    uv     = bodyUV(xy, room);
    BodyPoint point  = bodyAt(xy, room);
    float3    normal = point.normal;
    float3    origin = point.position + normal * room.radius * 1e-3;
    Images    images = { bodyPaint(uv, room), bodyBounce(uv, room) + lampHighlight(point, room) };

    const float total = accumulatedFrames * glossRays;
    for (uint index = 0; index < glossRays; index++) {
        float  number   = frame.index * glossRays + index;
        float2 sample   = float2((number + random(seed)) / total, fract(number * 0.618034 + frame.rotation.y));
        float3 facet    = facetSample(normal, metalRoughness, sample);
        float3 mirrored = reflect(-bodyView, facet);
        if (dot(mirrored, normal) <= 0) { continue; }
        ray reflection(origin, mirrored);
        intersection_result<> hit = makeIntersector().intersect(reflection, scene);
        Surface surface;
        float3  seen = float3(0);
        if (hitRoom(hit, reflection, room, surface)) {
            Frame single = { uint(number) % accumulatedFrames, frame.rotation.yx };
            seen = surface.albedo * tracedLamp(surface, 1, scene, room, single) * room.light
                 * reflectedWallGlow(surface.position.z, room);
        } else if (hit.type == intersection_type::none) {
            seen = wallsAbove(origin, mirrored, room);
        }
        images.light += metalFresnel(dot(facet, bodyView), room) * seen / glossRays;
    }
    return images;
}

/// One pixel of `traceRoom`, or of `traceLeaningRoom` when the room `leans`.
template <bool leans>
static void traceRoomAt(texture2d<float, access::write>  base,
                        texture2d<float, access::write>  light,
                        constant RoomLightUniforms&      uniforms,
                        primitive_acceleration_structure scene,
                        uint2                            pixel)
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room   room     = stagedRoom<leans>(uniforms);
    uint   seed     = pcg(pixel.x + pcg(pixel.y));
    float2 rotation = float2(random(seed), random(seed));
    float  top      = room.lamp.z;
    intersector<> nearest = makeIntersector();

    Images sum = { float3(0), float3(0) };
    for (uint index = 0; index < accumulatedFrames; index++) {
        Frame  frame = { index, rotation };
        float2 xy    = (float2(pixel) + float2(random(seed), random(seed))) * room.pointsPerPixel;
        ray    primary(float3(xy, top), float3(0, 0, -1));
        intersection_result<> hit = nearest.intersect(primary, scene);

        Images  images;
        Surface surface;
        if (hitRoom(hit, primary, room, surface)) {
            images = darkenedRight<leans>(tracedRoom(surface, scene, room, frame, seed), xy.x, room);
        } else if (hit.type != intersection_type::none) {
            images = tracedBody(xy, scene, room, frame, seed);
        } else {
            // Outside the rounded outline, which the view's corners clip: the top of the wall.
            Surface rim = surfaceAt(xy, room);
            images.base  = ambient;
            images.light = rim.albedo * lampTerm(rim.position, rim.normal, room.lamp, room) * room.light;
            images = darkenedRight<leans>(images, xy.x, room);
        }
        sum.base  += images.base;
        sum.light += images.light;
    }
    base.write(float4(sum.base / accumulatedFrames, 1), pixel);
    light.write(float4(sum.light / accumulatedFrames, 1), pixel);
}

kernel void traceRoom(texture2d<float, access::write>  base     [[texture(0)]],
                      texture2d<float, access::write>  light    [[texture(1)]],
                      constant RoomLightUniforms&      uniforms [[buffer(0)]],
                      primitive_acceleration_structure scene    [[buffer(1)]],
                      uint2                            pixel    [[thread_position_in_grid]])
{
    traceRoomAt<false>(base, light, uniforms, scene, pixel);
}

/// `traceRoom` for a room leaning left.
kernel void traceLeaningRoom(texture2d<float, access::write>  base     [[texture(0)]],
                             texture2d<float, access::write>  light    [[texture(1)]],
                             constant RoomLightUniforms&      uniforms [[buffer(0)]],
                             primitive_acceleration_structure scene    [[buffer(1)]],
                             uint2                            pixel    [[thread_position_in_grid]])
{
    traceRoomAt<true>(base, light, uniforms, scene, pixel);
}

// MARK: - The tilted view

// The tilted view (`RoomCamera.tilted` in Swift) looks into the room through its cell as through a
// window from the floor's front edge, the cell's bottom, to the back wall's top, the cell's top, so
// the floor recedes, the back wall rises behind it and the side walls narrow toward it. Its room has
// tall walls that meet the floor in coves and each other in the room's rounded corners, on a
// footprint that reaches far past the window toward the camera, so the room shows open at the front.
// Nothing is added to the room: the depth comes from the lamp's pool fading toward the front and into
// the back corners, the coves' soft occlusion and a darker front edge. The worker stands on its lowest
// point a little behind the floor's middle, its outline upright and facing the camera, thickened from
// front to back by a slab; its top may reach through the window. The lamp hangs over it and a little
// behind. On both paths the body's shadows are analytic, so they show no grain: a tight contact
// shadow where it meets the floor, and the lamp's soft shadow, whose penumbra widens away from it.

/// How far the walls' footprint reaches from the back wall, in floor depths, as
/// `RoomCamera.Perspective.footprintDepth`.
constant float footprintReach = 2;

/// How much darker the floor and walls are at the front edge, and over what share of the floor's
/// depth they darken toward it.
constant float frontShade = 0.35;
constant float frontReach = 0.3;

/// Where the precomputed occlusion of the coves and corners looks along a surface's normal, as a
/// share of the short side, and how much of the room's ambient light it takes there at most.
constant float coveReach  = 0.04;
constant float coveHiding = 0.45;

/// How much of the room the precomputed metal mirrors, for the ray tracer's glossy reflections.
constant float mirrorShare = 0.6;

/// The most steps a ray takes through the body's bounding sphere, and the shortest, in sphere radii.
constant uint  bodySteps   = 96;
constant float bodyMinStep = 1.0 / 32;

/// How far behind the standing body the lamp hangs, as a share of the short side.
constant float lampBehind = 0.2;

/// How far from the body its contact shadow reaches, in sphere radii, and how much of the lamp's
/// light it takes where the body touches.
constant float contactReach = 0.25;
constant float contactLight = 0.8;

/// Camera is the tilted view's eye, the window's centre, and the window's up and its normal toward
/// the eye, in scene points.
struct Camera {
    float3 eye;
    float3 centre;
    float3 up;
    float3 normal;
};

/// The tilted view's room: the body standing on its lowest point a little behind the floor's middle,
/// the pool's frame centred on it as the room is from above, and the lamp over it and a little behind,
/// so the body's shadow falls toward the camera; when the room `leans`, moved left as the stage says.
template <bool leans>
static Room makeTiltedRoom(constant RoomLightUniforms& uniforms) {
    Room room      = makeRoom(uniforms);
    room.isTilted  = true;
    room.depth     = uniforms.camera.x;
    room.fillet    = uniforms.room.w;
    room.footprint = float2(room.size.x, footprintReach * room.depth);
    room.size      = float2(room.size.x, 2 * uniforms.camera.w);
    room.bodySlab  = uniforms.body.z * room.radius;
    room.body      = float3(room.size * 0.5, room.bodyBottom * room.radius);
    room.lamp      = float3(poolCentre.x * room.size.x, room.body.y - lampBehind * room.side, lampHeightShare * room.side);
    if (leans) {
        room.lean = uniforms.stage.y;
        leanLeft(room, uniforms);
    }
    return room;
}

/// The camera `RoomCamera.Perspective` describes: the window's slant length is the cell's height, and
/// in a room leaning left the eye stands across from the worker.
template <bool leans>
static Camera makeCamera(constant RoomLightUniforms& uniforms) {
    float  height = uniforms.room.y;
    float  depth  = uniforms.camera.x;
    float  top    = uniforms.camera.y;
    Camera camera;
    camera.centre = float3(0.5 * uniforms.room.x, 0.5 * depth, 0.5 * top);
    camera.normal = float3(0, top, depth) / height;
    camera.up     = float3(0, -depth, top) / height;
    camera.eye    = camera.centre + uniforms.camera.z * camera.normal;
    if (leans) { camera.eye.x = uniforms.stage.x; }
    return camera;
}

/// The point of the window that shows at `xy` of the cell, in points with y down.
static float3 windowPoint(float2 xy, constant RoomLightUniforms& uniforms, Camera camera) {
    return camera.centre + float3(xy.x - 0.5 * uniforms.room.x, 0, 0) + (0.5 * uniforms.room.y - xy.y) * camera.up;
}

/// How far `position` lies inside the tilted room, negative outside, and in `normal` the facing of
/// its nearest surface, into the room: the floor, a wall, or the cove between them, a quarter circle
/// of the fillet's radius. The walls follow the footprint's rounded outline.
static float tiltedInside(float3 position, Room room, thread float3& normal) {
    Room   walls = room;
    walls.size   = room.footprint;
    float2 inward;
    float  wall = insideDistance(position.xy, walls, inward);
    float2 cove = room.fillet - float2(wall, position.z);
    if (cove.x > 0 && cove.y > 0) {
        normal = normalize(float3(inward * cove.x, cove.y));
        return room.fillet - length(cove);
    }
    normal = wall < position.z ? float3(inward, 0) : float3(0, 0, 1);
    return min(wall, position.z);
}

/// The floor, wall or cove nearest `position`, its albedo turning from the floor's to the walls'.
static Surface tiltedSurfaceAt(float3 position, Room room) {
    Surface surface;
    float   inside   = tiltedInside(position, room, surface.normal);
    surface.position = position - inside * surface.normal;
    surface.albedo   = mix(floorAlbedo, wallAlbedo, 1 - surface.normal.z);
    return surface;
}

/// Where the camera's ray from the window point `start` along `direction` meets the floor or a wall.
static float3 tiltedRoomHit(float3 start, float3 direction, Room room) {
    float3 position = start;
    float3 normal;
    for (uint step = 0; step < 48; step++) {
        float inside = tiltedInside(position, room, normal);
        if (inside < 1e-3 * room.side) { break; }
        position += direction * inside;
    }
    return position;
}

/// How much of their light the floor and walls keep, less toward the front edge.
static float frontFade(float3 position, Room room) {
    return 1 - frontShade * smoothstep(1 - frontReach, 1.0, position.y / room.depth);
}

/// How open a floor or wall point is to the room, for its ambient light: less where the walls, the
/// floor and the coves come close along its normal.
static float tiltedOpenness(Surface surface, Room room) {
    float3 normal;
    float  hidden = 0;
    for (uint step = 1; step <= 4; step++) {
        float reach = coveReach * room.side * step;
        hidden += saturate(1 - tiltedInside(surface.position + surface.normal * reach, room, normal) / reach);
    }
    return 1 - coveHiding * hidden / 4;
}

/// The light alone at a floor or wall point of the tilted room: the lamp with the body's soft
/// shadow, tested against `samples` points of the lamp, and the light floor and walls bounce to each
/// other, estimated from the nearest wall: the floor's pool up the wall, strongest at its foot, and
/// the wall's glow onto the floor before it.
static float3 tiltedAnalyticLight(Surface surface, uint samples, Room room) {
    float direct = surface.albedo * lampTerm(surface.position, surface.normal, room.lamp, room)
                 * (1 - bodyOcclusion(surface.position, samples, room));
    Room   walls = room;
    walls.size   = room.footprint;
    float2 inward;
    float  wall     = insideDistance(surface.position.xy, walls, inward);
    float3 below    = float3(surface.position.xy + inward * max(room.fillet - wall, 0.0), 0);
    float  floor    = floorAlbedo * lampTerm(below, float3(0, 0, 1), room.lamp, room)
                    * (1 - bodyOcclusion(below, reflectionSamples, room));
    float3 above    = float3(surface.position.xy - inward * wall, 0.3 * room.side);
    float  fromWall = wallAlbedo * lampTerm(above, float3(inward, 0), room.lamp, room);
    float  rise     = (1 - surface.normal.z) * exp(-surface.position.z / (0.3 * room.side));
    float  spread   = surface.normal.z * exp(-wall / (0.1 * room.side));
    return (direct + surface.albedo * (0.45 * rise * floor + 0.15 * spread * fromWall)) * room.light;
}

/// A point in the standing body's own frame: x across and y down its outline around `room.body.xy`,
/// as `corePoint` reads points from above, and z how far in front of the body's middle it lies.
static float3 standingLocal(float3 position, Room room) {
    return float3(position.x, room.body.y + room.body.z - position.z, position.y - room.body.y);
}

/// How deep `position` lies inside the standing body, negative outside: within the slab, and before
/// and behind it the bevel's quarter circle with the dome, as `bodyAt` shapes the top from above.
static float bodyInside(float3 position, Room room) {
    float3 local  = standingLocal(position, room);
    float  across = length(local.xy - corePoint(local.xy, room));
    if (across >= room.bodyCorner) { return room.bodyCorner - across; }
    float rise = sqrt(square(room.bodyCorner) - square(across));
    float dome = room.bodyDome > 0 ? room.bodyDome * (1 - square(outlineGauge(local.xy, room).x)) : 0;
    return room.bodySlab + rise + dome - abs(local.z);
}

/// How far along the unit `direction` from `origin` the ray first meets the body, or -1 when it
/// passes by. Through the body's bounding sphere it steps as far as the body without its dome is,
/// less the dome's height, which the body cannot be nearer than, at least `bodyMinStep`, and halves
/// the step that enters it.
static float bodyHit(float3 origin, float3 direction, Room room) {
    if (!room.isOccupied) { return -1; }
    float3 centre = room.body;
    float  bound  = length(float2(room.coreSize + room.bodyCorner, room.bodySlab + room.bodyCorner + room.bodyDome));
    float3 offset = origin - centre;
    float  along  = -dot(offset, direction);
    float  miss   = dot(offset, offset) - along * along;
    if (miss > bound * bound) { return -1; }
    float reach = sqrt(bound * bound - miss);
    float end   = along + reach;
    float near  = max(along - reach, 0.0);
    float far   = near;
    for (uint step = 0; step < bodySteps && far <= end; step++) {
        float3 position = origin + direction * far;
        if (bodyInside(position, room) > 0) {
            for (uint halving = 0; halving < 10; halving++) {
                float middle = 0.5 * (near + far);
                if (bodyInside(origin + direction * middle, room) > 0) { far = middle; } else { near = middle; }
            }
            return far;
        }
        float  free = length(position - nearestCore(position, room)) - room.bodyCorner - room.bodyDome;
        near = far;
        far += max(free, bodyMinStep * room.radius);
    }
    return -1;
}

/// The standing body's facing at a point of its surface: on the slab's band away from the core, and
/// before and behind it as `bodyAt` faces the top from above, turned upright.
static float3 bodyNormalAt(float3 position, Room room) {
    float3 local   = standingLocal(position, room);
    float2 outward = local.xy - corePoint(local.xy, room);
    float3 facing  = float3(outward / max(length(outward), 1e-6), 0);
    if (abs(local.z) > room.bodySlab) {
        outward     *= min(1.0, room.bodyCorner / max(length(outward), 1e-6));
        float  rise  = sqrt(max(square(room.bodyCorner) - dot(outward, outward), 0.0));
        float3 gauge = room.bodyDome > 0 ? outlineGauge(local.xy, room) : float3(0);
        facing       = normalize(float3(outward + 2 * room.bodyDome * gauge.x * gauge.yz * rise, rise));
        facing.z    *= sign(local.z);
    }
    return float3(facing.x, facing.z, -facing.y);
}

/// How much the standing body hides of a floor or wall point right beside it: all of it where they
/// touch, falling off within `contactReach` of the sphere's radius, so the body sits on the floor.
static float bodyContact(Surface surface, Room room) {
    if (!room.isOccupied) { return 0; }
    float3 toCore = nearestCore(surface.position, room) - surface.position;
    float  apart  = length(toCore);
    float  gap    = max(apart - room.bodyCorner, 0.0);
    return saturate(dot(surface.normal, toCore / max(apart, 1e-4))) * exp(-gap / (contactReach * room.radius));
}

/// The body's paint coordinates at `position` as the camera sees it: the sphere's unit square
/// around the body's centre, laid across the view, y down.
static float2 tiltedBodyUV(float3 position, Room room, Camera camera) {
    float3 offset = position - room.body;
    return 0.5 + float2(offset.x, -dot(offset, camera.up)) / (2 * room.radius);
}

/// Whether `position` lies in front of the window, where the camera is: the room is open there.
static bool isBeforeWindow(float3 position, Camera camera) {
    return dot(position - camera.centre, camera.normal) > 0;
}

/// The room the precomputed metal mirrors at a point of the body seen along `direction`: the floor
/// or wall the mirrored ray meets, lit as `tiltedAnalyticLight` lights it, fading out where the ray
/// leaves through the window or over the walls, as the ray tracer's glossy rays blur that edge.
static float3 tiltedMirror(float3 position, float3 normal, float3 direction, Room room, Camera camera) {
    float3 mirrored = reflect(direction, normal);
    float3 start    = position + normal * 1e-3 * room.radius;
    float  exit     = 1e6;
    if (mirrored.z < 0) { exit = min(exit, -start.z / mirrored.z); }
    if (mirrored.y < 0) { exit = min(exit, -start.y / mirrored.y); }
    if (mirrored.x < 0) { exit = min(exit, -start.x / mirrored.x); }
    if (mirrored.x > 0) { exit = min(exit, (room.footprint.x - start.x) / mirrored.x); }
    if (exit > 1e5) { return float3(0); }
    float3  hit     = start + mirrored * exit;
    float   before  = dot(hit - camera.centre, camera.normal);
    Surface surface = tiltedSurfaceAt(hit, room);
    return tiltedAnalyticLight(surface, reflectionSamples, room) * frontFade(surface.position, room)
         * (1 - smoothstep(-0.15 * room.side, 0.15 * room.side, before));
}

/// One pixel of `precomputeTiltedRoom`, or of `precomputeTiltedLeaningRoom` when the room `leans`.
template <bool leans>
static void precomputeTiltedRoomAt(texture2d<float, access::write> base,
                                   texture2d<float, access::write> light,
                                   constant RoomLightUniforms&     uniforms,
                                   uint2                           pixel)
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room    room      = makeTiltedRoom<leans>(uniforms);
    Camera  camera    = makeCamera<leans>(uniforms);
    float2  xy        = (float2(pixel) + 0.5) * room.pointsPerPixel;
    float3  window    = windowPoint(xy, uniforms, camera);
    Surface surface   = tiltedSurfaceAt(tiltedRoomHit(window, normalize(window - camera.eye), room), room);
    float   fade      = frontFade(surface.position, room);
    float   openness  = tiltedOpenness(surface, room);
    float   contact   = bodyContact(surface, room);
    Images  images    = {
        ambient * openness * (1 - bodyAmbientOcclusion(surface, room)) * (1 - contact) * fade,
        tiltedAnalyticLight(surface, occlusionSamples, room) * (1 - occlusionLightShare * (1 - openness))
            * (1 - contactLight * contact) * fade
    };
    images = darkenedRight<leans>(images, surface.position.x, room);

    // The body, found at four points of the pixel so its silhouette is smooth, shaded at the first.
    float  coverage = 0;
    float3 hit      = 0;
    float3 seen     = 0;
    for (uint corner = 0; corner < 4 && room.isOccupied; corner++) {
        float2 offset    = (float2(corner & 1, corner >> 1) - 0.5) * 0.5;
        float3 direction = normalize(windowPoint((float2(pixel) + 0.5 + offset) * room.pointsPerPixel, uniforms, camera) - camera.eye);
        float  distance  = bodyHit(camera.eye, direction, room);
        if (distance <= 0) { continue; }
        if (coverage == 0) {
            hit  = camera.eye + direction * distance;
            seen = direction;
        }
        coverage += 0.25;
    }
    if (coverage > 0) {
        BodyPoint point     = { hit, bodyNormalAt(hit, room) };
        float2    uv        = tiltedBodyUV(hit, room, camera);
        float3    reflected = metalFresnel(dot(point.normal, -seen), room) * mirrorShare
                            * tiltedMirror(hit, point.normal, seen, room, camera)
                            + lampHighlight(point, -seen, room);
        images.base  = mix(images.base, bodyPaint(uv, room), coverage);
        images.light = mix(images.light, reflected + bodyBounce(uv, room), coverage);
    }
    base.write(float4(images.base, 1), pixel);
    light.write(float4(images.light, 1), pixel);
}

kernel void precomputeTiltedRoom(texture2d<float, access::write> base     [[texture(0)]],
                                 texture2d<float, access::write> light    [[texture(1)]],
                                 constant RoomLightUniforms&     uniforms [[buffer(0)]],
                                 uint2                           pixel    [[thread_position_in_grid]])
{
    precomputeTiltedRoomAt<false>(base, light, uniforms, pixel);
}

/// `precomputeTiltedRoom` for a room leaning left.
kernel void precomputeTiltedLeaningRoom(texture2d<float, access::write> base     [[texture(0)]],
                                        texture2d<float, access::write> light    [[texture(1)]],
                                        constant RoomLightUniforms&     uniforms [[buffer(0)]],
                                        uint2                           pixel    [[thread_position_in_grid]])
{
    precomputeTiltedRoomAt<true>(base, light, uniforms, pixel);
}

/// One frame of a floor or wall point of the tilted room: the lamp's light under the body's soft
/// shadow, `shadow`, which the pixel estimates once analytically so it shows no grain; the ambient
/// light, occluded by the walls and floor a traced ray meets nearby; one traced bounce; and the body's
/// contact and ambient occlusion, analytic too.
static Images tracedTiltedRoom(Surface surface, float shadow, primitive_acceleration_structure scene, Room room, Frame frame, thread uint& seed) {
    Images images;
    images.light = surface.albedo * lampTerm(surface.position, surface.normal, room.lamp, room) * (1 - shadow) * room.light;

    float2 stratum = float2(frame.index % 8, frame.index / 8);
    float2 sample  = fract((stratum + float2(random(seed), random(seed))) / 8 + frame.rotation);
    ray    bounce(surface.position + surface.normal * room.side * 1e-3, cosineSample(surface.normal, sample));
    intersection_result<> hit = makeIntersector().intersect(bounce, scene);
    // The body's own occlusion is the analytic contact below, so only the walls and floor count here.
    bool isOccluded = hit.type != intersection_type::none && hit.geometry_id != bodyGeometry
                   && hit.distance < occlusionReach * room.side;
    images.base   = isOccluded ? float3(0) : ambient;
    images.light *= isOccluded ? 1 - occlusionLightShare : 1;

    Surface other;
    if (hitRoom(hit, bounce, room, other)) {
        Frame single = { frame.index, frame.rotation.yx };
        images.light += surface.albedo * other.albedo * tracedLamp(other, 1, scene, room, single) * room.light;
    }
    float contact = bodyContact(surface, room);
    float fade    = frontFade(surface.position, room);
    images.base  *= (1 - contact) * (1 - bodyAmbientOcclusion(surface, room)) * fade;
    images.light *= (1 - contactLight * contact) * fade;
    return images;
}

/// One frame of the body at `position`, seen along `direction`: its paint, the lamp mirrored by its
/// metal, the room reflected through `glossRays` traced GGX facets with their shadows, and the
/// crescent of room light at the bottom. Rays that leave through the window see nothing.
static Images tracedTiltedBody(float3 position, float3 direction, primitive_acceleration_structure scene, Room room, Camera camera, Frame frame, thread uint& seed) {
    BodyPoint point  = { position, bodyNormalAt(position, room) };
    float3    normal = point.normal;
    float3    origin = position + normal * room.radius * 1e-3;
    float2    uv     = tiltedBodyUV(position, room, camera);
    Images    images = { bodyPaint(uv, room), bodyBounce(uv, room) + lampHighlight(point, -direction, room) };

    const float total = accumulatedFrames * glossRays;
    for (uint index = 0; index < glossRays; index++) {
        float  number   = frame.index * glossRays + index;
        float2 sample   = float2((number + random(seed)) / total, fract(number * 0.618034 + frame.rotation.y));
        float3 facet    = facetSample(normal, metalRoughness, sample);
        float3 mirrored = reflect(direction, facet);
        if (dot(mirrored, normal) <= 0) { continue; }
        ray reflection(origin, mirrored);
        intersection_result<> hit = makeIntersector().intersect(reflection, scene);
        Surface surface;
        if (!hitRoom(hit, reflection, room, surface) || isBeforeWindow(surface.position, camera)) { continue; }
        Frame  single = { uint(number) % accumulatedFrames, frame.rotation.yx };
        float3 seen   = surface.albedo * tracedLamp(surface, 1, scene, room, single) * room.light
                      * frontFade(surface.position, room);
        images.light += metalFresnel(dot(facet, -direction), room) * seen / glossRays;
    }
    return images;
}

/// One pixel of `traceTiltedRoom`, or of `traceTiltedLeaningRoom` when the room `leans`.
template <bool leans>
static void traceTiltedRoomAt(texture2d<float, access::write>  base,
                              texture2d<float, access::write>  light,
                              constant RoomLightUniforms&      uniforms,
                              primitive_acceleration_structure scene,
                              uint2                            pixel)
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room   room     = makeTiltedRoom<leans>(uniforms);
    Camera camera   = makeCamera<leans>(uniforms);
    uint   seed     = pcg(pixel.x + pcg(pixel.y));
    float2 rotation = float2(random(seed), random(seed));
    intersector<> nearest = makeIntersector();
    // The body's shadow where the pixel's middle meets the room, smooth over the lamp's whole disc.
    float3 middle = windowPoint((float2(pixel) + 0.5) * room.pointsPerPixel, uniforms, camera);
    float  shadow = bodyOcclusion(tiltedRoomHit(middle, normalize(middle - camera.eye), room), occlusionSamples, room);

    Images sum = { float3(0), float3(0) };
    for (uint index = 0; index < accumulatedFrames; index++) {
        Frame  frame     = { index, rotation };
        float2 xy        = (float2(pixel) + float2(random(seed), random(seed))) * room.pointsPerPixel;
        float3 window    = windowPoint(xy, uniforms, camera);
        float3 direction = normalize(window - camera.eye);
        // The body first, from the eye, since its top may reach through the window.
        float  distance  = bodyHit(camera.eye, direction, room);

        Images images;
        if (distance > 0) {
            images = tracedTiltedBody(camera.eye + direction * distance, direction, scene, room, camera, frame, seed);
        } else {
            ray primary(window, direction);
            intersection_result<> hit = nearest.intersect(primary, scene);
            Surface surface;
            if (hitRoom(hit, primary, room, surface)) {
                images = darkenedRight<leans>(tracedTiltedRoom(surface, shadow, scene, room, frame, seed), surface.position.x, room);
            } else if (hit.type != intersection_type::none) {
                images = tracedTiltedBody(window + direction * hit.distance, direction, scene, room, camera, frame, seed);
            } else {
                // Behind the back corners' rounding, which the view's corners clip: the wall there.
                Surface wall = tiltedSurfaceAt(window, room);
                images = darkenedRight<leans>(tracedTiltedRoom(wall, shadow, scene, room, frame, seed), wall.position.x, room);
            }
        }
        sum.base  += images.base;
        sum.light += images.light;
    }
    base.write(float4(sum.base / accumulatedFrames, 1), pixel);
    light.write(float4(sum.light / accumulatedFrames, 1), pixel);
}

kernel void traceTiltedRoom(texture2d<float, access::write>  base     [[texture(0)]],
                            texture2d<float, access::write>  light    [[texture(1)]],
                            constant RoomLightUniforms&      uniforms [[buffer(0)]],
                            primitive_acceleration_structure scene    [[buffer(1)]],
                            uint2                            pixel    [[thread_position_in_grid]])
{
    traceTiltedRoomAt<false>(base, light, uniforms, scene, pixel);
}

/// `traceTiltedRoom` for a room leaning left.
kernel void traceTiltedLeaningRoom(texture2d<float, access::write>  base     [[texture(0)]],
                                   texture2d<float, access::write>  light    [[texture(1)]],
                                   constant RoomLightUniforms&      uniforms [[buffer(0)]],
                                   primitive_acceleration_structure scene    [[buffer(1)]],
                                   uint2                            pixel    [[thread_position_in_grid]])
{
    traceTiltedRoomAt<true>(base, light, uniforms, scene, pixel);
}

// MARK: - Denoised frames

// With MetalFX's denoised upscaler (`RoomDenoiser` in Swift), the tilted room is traced in frames of a
// few samples per pixel at a reduced size, and the denoiser turns them into the full-size images. Each
// sample traces the lamp's light with shadow rays to points of its disc, so the body's shadow follows
// its mesh exactly, its penumbra widening with distance; the walls' and floor's occlusion counts the
// body too, which gives the contact shadow. The bounce and the reflections on the body are traced as
// in `traceTiltedRoom`. Every sequence is progressive per pixel, so each sample lands where the earlier
// ones left gaps, and shifted per pixel, so neighbours share no pattern. A room leaning left has its
// twin, `traceTiltedLeaningRoomFrame`, darkened toward its right end as `traceTiltedLeaningRoom` is.

// Shadow rays per sample from a floor or wall point to the lamp.
constant uint burstShadowRays = 2;

/// BurstFrame matches `RoomDenoiser.Frame` in Swift: the transform from scene points to the clip space
/// of the depth the frame writes, the room's points per traced pixel across and down, the frame's
/// sub-pixel jitter in traced pixels, its index in the burst, and the samples it averages per pixel.
struct BurstFrame {
    float4x4 clip;
    float2   pointsPerPixel;
    float2   jitter;
    uint     index;
    uint     samples;
};

/// Guide is what the denoiser reads of a pixel besides its noisy light, noise-free from the scene.
struct Guide {
    float3 position;
    float3 normal;
    float3 diffuse;    // the diffuse albedo
    float3 specular;   // the specular albedo
    float  roughness;
};

/// Shifts is a pixel's own offsets of the sequences it samples, so neighbours share no pattern.
struct Shifts {
    float2 lamp;     // the lamp's points a floor or wall point sees
    float4 bounce;   // a bounce's direction, and the lamp's point it then sees
    float4 gloss;    // a reflection's facet, and the lamp's point it then sees
};

/// The `index`th point of the R2 sequence shifted by `shift`: every run of it from the start covers
/// the unit square evenly.
static float2 progressive(float2 shift, uint index) {
    return fract(shift + float(index) * float2(0.7548776662, 0.5698402910));
}

/// The `index`th point of the R4 sequence shifted by `shift`, for a sample nested in another: a
/// bounce or reflection's direction in `xy` and the lamp's point it then sees in `zw`. Two R2 points
/// of one index would tie the two together, so each pixel would settle on its own error.
static float4 progressive4(float4 shift, uint index) {
    return fract(shift + float(index) * float4(0.8566748839, 0.7338918566, 0.6287067210, 0.5385972572));
}

/// The lamp's light on a floor or wall point from the point of its disc at `sample`, or none when
/// something stands between them.
static float lampPointLight(Surface surface, float2 sample, primitive_acceleration_structure scene, Room room) {
    float3 lampPoint = lampSample(room, sample);
    if (!sees(surface.position, surface.normal, lampPoint, scene, room)) { return 0; }
    return lampTerm(surface.position, surface.normal, lampPoint, room);
}

/// Sample `index` of a floor or wall point of the tilted room: the lamp's light through traced shadow
/// rays, the ambient light occluded by whatever a traced ray meets nearby, the body included, and one
/// traced bounce.
static Images denoisedTiltedRoom(Surface surface, primitive_acceleration_structure scene, Room room, uint index, Shifts shifts) {
    float direct = 0;
    for (uint sample = 0; sample < burstShadowRays; sample++) {
        float2 lampPoint = progressive(shifts.lamp, index * burstShadowRays + sample);
        direct += lampPointLight(surface, lampPoint, scene, room) / burstShadowRays;
    }
    Images images;
    images.light = surface.albedo * direct * room.light;

    float4 nested = progressive4(shifts.bounce, index);
    ray    bounce(surface.position + surface.normal * room.side * 1e-3, cosineSample(surface.normal, nested.xy));
    intersection_result<> hit = makeIntersector().intersect(bounce, scene);
    bool isOccluded = hit.type != intersection_type::none && hit.distance < occlusionReach * room.side;
    images.base   = isOccluded ? float3(0) : ambient;
    images.light *= isOccluded ? 1 - occlusionLightShare : 1;

    Surface other;
    if (hitRoom(hit, bounce, room, other)) {
        images.light += surface.albedo * other.albedo * lampPointLight(other, nested.zw, scene, room) * room.light;
    }
    float fade = frontFade(surface.position, room);
    images.base  *= fade;
    images.light *= fade;
    return images;
}

/// Sample `index` of the body at `position`, seen along `direction`, as `tracedTiltedBody` shades it,
/// with its reflection rays drawn from progressive sequences.
static Images denoisedTiltedBody(float3 position, float3 direction, primitive_acceleration_structure scene, Room room,
                                 Camera camera, uint index, Shifts shifts) {
    BodyPoint point  = { position, bodyNormalAt(position, room) };
    float3    normal = point.normal;
    float3    origin = position + normal * room.radius * 1e-3;
    float2    uv     = tiltedBodyUV(position, room, camera);
    Images    images = { bodyPaint(uv, room), bodyBounce(uv, room) + lampHighlight(point, -direction, room) };

    for (uint sample = 0; sample < glossRays; sample++) {
        float4 nested   = progressive4(shifts.gloss, index * glossRays + sample);
        float3 facet    = facetSample(normal, metalRoughness, nested.xy);
        float3 mirrored = reflect(direction, facet);
        if (dot(mirrored, normal) <= 0) { continue; }
        ray reflection(origin, mirrored);
        intersection_result<> hit = makeIntersector().intersect(reflection, scene);
        Surface surface;
        if (!hitRoom(hit, reflection, room, surface) || isBeforeWindow(surface.position, camera)) { continue; }
        float3 seen = surface.albedo * lampPointLight(surface, nested.zw, scene, room) * room.light
                    * frontFade(surface.position, room);
        images.light += metalFresnel(dot(facet, -direction), room) * seen / glossRays;
    }
    return images;
}

/// The guide of a floor or wall point: its albedo darkened toward the front edge, and toward the right
/// end when the room `leans`, and no gloss.
template <bool leans>
static Guide roomGuide(Surface surface, Room room) {
    float  keep   = leans ? rightDarkness(surface.position.x, room) : 1;
    float3 albedo = float3(surface.albedo * frontFade(surface.position, room) * keep);
    Guide  guide  = { surface.position, surface.normal, albedo, float3(0), 1 };
    return guide;
}

/// The guide of a point of the body seen along `direction`: metal, its little diffuse light its paint,
/// its reflectance the specular albedo, as the denoiser expects of metals.
static Guide bodyGuide(float3 position, float3 direction, Room room, Camera camera) {
    float3 normal = bodyNormalAt(position, room);
    float3 paint  = bodyPaint(tiltedBodyUV(position, room, camera), room);
    Guide  guide  = { position, normal, paint, metalFresnel(dot(normal, -direction), room), metalRoughness };
    return guide;
}

/// Sample `index` of the tilted room at `xy` of the cell, and in `guide` the scene there; a room that
/// `leans` goes dark toward its right end.
template <bool leans>
static Images denoisedSample(float2 xy, constant RoomLightUniforms& uniforms, Room room, Camera camera,
                             primitive_acceleration_structure scene, uint index, Shifts shifts, thread Guide& guide) {
    float3 window    = windowPoint(xy, uniforms, camera);
    float3 direction = normalize(window - camera.eye);
    // The body first, from the eye, since its top may reach through the window.
    float   distance = bodyHit(camera.eye, direction, room);
    float3  position = camera.eye + direction * distance;
    Surface surface;
    if (distance <= 0) {
        ray primary(window, direction);
        intersection_result<> hit = makeIntersector().intersect(primary, scene);
        if (hit.type == intersection_type::none) {
            // Behind the back corners' rounding, which the view's corners clip: the wall there.
            surface = tiltedSurfaceAt(window, room);
        } else if (!hitRoom(hit, primary, room, surface)) {
            distance = hit.distance;
            position = window + direction * hit.distance;
        }
    }
    if (distance > 0) {
        guide = bodyGuide(position, direction, room, camera);
        return denoisedTiltedBody(position, direction, scene, room, camera, index, shifts);
    }
    guide = roomGuide<leans>(surface, room);
    return darkenedRight<leans>(denoisedTiltedRoom(surface, scene, room, index, shifts), surface.position.x, room);
}

/// One pixel of `traceTiltedRoomFrame`, or of `traceTiltedLeaningRoomFrame` when the room `leans`.
template <bool leans>
static void traceTiltedRoomFrameAt(texture2d<float, access::write>  base,
                                   texture2d<float, access::write>  light,
                                   texture2d<float, access::write>  depth,
                                   texture2d<float, access::write>  normals,
                                   texture2d<float, access::write>  diffuse,
                                   texture2d<float, access::write>  specular,
                                   texture2d<float, access::write>  roughness,
                                   constant RoomLightUniforms&      uniforms,
                                   primitive_acceleration_structure scene,
                                   constant BurstFrame&             frame,
                                   uint2                            pixel)
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room   room   = makeTiltedRoom<leans>(uniforms);
    Camera camera = makeCamera<leans>(uniforms);
    uint   seed   = pcg(pixel.x + pcg(pixel.y));
    Shifts shifts;
    shifts.lamp   = float2(random(seed), random(seed));
    shifts.bounce = float4(random(seed), random(seed), random(seed), random(seed));
    shifts.gloss  = float4(random(seed), random(seed), random(seed), random(seed));

    Guide  guide;
    Images images = { float3(0), float3(0) };
    for (uint sample = 0; sample < frame.samples; sample++) {
        // The first sample at the frame's jittered centre, the others over the pixel, so edges come out smooth.
        float2 offset = sample == 0 ? float2(0) : progressive(float2(0.5), sample) - 0.5;
        float2 xy     = (float2(pixel) + 0.5 + frame.jitter + offset) * frame.pointsPerPixel;
        Guide  seen;
        Images one    = denoisedSample<leans>(xy, uniforms, room, camera, scene, frame.index * frame.samples + sample, shifts, seen);
        if (sample == 0) { guide = seen; }
        images.base  += one.base / frame.samples;
        images.light += one.light / frame.samples;
    }
    float4 clip = frame.clip * float4(guide.position, 1);
    base.write(float4(images.base, 1), pixel);
    light.write(float4(images.light, 1), pixel);
    depth.write(float4(clip.z / clip.w), pixel);
    normals.write(float4(guide.normal, 0), pixel);
    diffuse.write(float4(guide.diffuse, 1), pixel);
    specular.write(float4(guide.specular, 1), pixel);
    roughness.write(float4(guide.roughness), pixel);
}

/// One frame of the tilted room at the denoiser's input size: the noisy base and light images, each
/// pixel's `samples` spread over it, and the guides of the scene at the frame's jittered centre.
kernel void traceTiltedRoomFrame(texture2d<float, access::write>  base      [[texture(0)]],
                                 texture2d<float, access::write>  light     [[texture(1)]],
                                 texture2d<float, access::write>  depth     [[texture(2)]],
                                 texture2d<float, access::write>  normals   [[texture(3)]],
                                 texture2d<float, access::write>  diffuse   [[texture(4)]],
                                 texture2d<float, access::write>  specular  [[texture(5)]],
                                 texture2d<float, access::write>  roughness [[texture(6)]],
                                 constant RoomLightUniforms&      uniforms  [[buffer(0)]],
                                 primitive_acceleration_structure scene     [[buffer(1)]],
                                 constant BurstFrame&             frame     [[buffer(2)]],
                                 uint2                            pixel     [[thread_position_in_grid]])
{
    traceTiltedRoomFrameAt<false>(base, light, depth, normals, diffuse, specular, roughness, uniforms, scene, frame, pixel);
}

/// `traceTiltedRoomFrame` for a room leaning left.
kernel void traceTiltedLeaningRoomFrame(texture2d<float, access::write>  base      [[texture(0)]],
                                        texture2d<float, access::write>  light     [[texture(1)]],
                                        texture2d<float, access::write>  depth     [[texture(2)]],
                                        texture2d<float, access::write>  normals   [[texture(3)]],
                                        texture2d<float, access::write>  diffuse   [[texture(4)]],
                                        texture2d<float, access::write>  specular  [[texture(5)]],
                                        texture2d<float, access::write>  roughness [[texture(6)]],
                                        constant RoomLightUniforms&      uniforms  [[buffer(0)]],
                                        primitive_acceleration_structure scene     [[buffer(1)]],
                                        constant BurstFrame&             frame     [[buffer(2)]],
                                        uint2                            pixel     [[thread_position_in_grid]])
{
    traceTiltedRoomFrameAt<true>(base, light, depth, normals, diffuse, specular, roughness, uniforms, scene, frame, pixel);
}

// MARK: - Checks

/// The body's normal at each of `points`, room coordinates in points, for the tests: the check that
/// the circle is still the sphere it was.
kernel void bodyNormals(constant RoomLightUniforms& uniforms [[buffer(0)]],
                        device const float2*        points   [[buffer(1)]],
                        device float4*              normals  [[buffer(2)]],
                        uint                        index    [[thread_position_in_grid]])
{
    normals[index] = float4(bodyAt(points[index], makeRoom(uniforms)).normal, 0);
}

/// Whether the tilted camera's ray through each of `points`, cell coordinates in points, meets the
/// body, in a room centred or leaning left, for the tests: the check that the brows sit on it.
kernel void tiltedBodyHits(constant RoomLightUniforms& uniforms [[buffer(0)]],
                           device const float2*        points   [[buffer(1)]],
                           device float*               hits     [[buffer(2)]],
                           uint                        index    [[thread_position_in_grid]])
{
    bool   leans     = uniforms.stage.y > 0;
    Room   room      = leans ? makeTiltedRoom<true>(uniforms) : makeTiltedRoom<false>(uniforms);
    Camera camera    = leans ? makeCamera<true>(uniforms) : makeCamera<false>(uniforms);
    float3 direction = normalize(windowPoint(points[index], uniforms, camera) - camera.eye);
    hits[index] = bodyHit(camera.eye, direction, room) > 0 ? 1 : 0;
}
