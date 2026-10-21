//
//  RoomLight.metal
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

// A room seen straight from above, orthographic: a floor with a rounded outline, low walls that curve
// up from it as a cove, so their faces show from above, and the worker as a glossy metal sphere at
// the centre resting on the floor. A soft disc lamp above the sphere, a little toward the top, lights
// the room in the worker's status colour; it casts an elliptical pool as wide as the room. Scene
// units are points: x to the right, y down as on screen, z up from the floor.
//
// Every kernel writes two linear images: `base`, the room without its worker's light, and `light`,
// the light alone with its bleed on the walls and its reflections on the sphere. `resolveRoom` adds
// them with a weight, tone maps once and writes sRGB, which lets the light pulse without rendering.
// `traceRoom` traces the scene against an acceleration structure; `precomputeRoom` evaluates the
// same scene analytically.

#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace raytracing;

/// RoomLightUniforms matches `RoomLightUniforms.Packed` in Swift: four float4, 64 bytes.
struct RoomLightUniforms {
    float4 light;   // sRGB colour, strength in w
    float4 tint;    // sRGB tint, w is 1 when the worker is in the room
    float4 room;    // width and height in points, points per pixel, unused
    float4 shape;   // wall height, wall reach, sphere radius, corner radius, in points
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

constant float  floorAlbedo = 0.5;
constant float  wallAlbedo  = 0.7;
constant float  exposure    = 0.42;
constant float3 ambient     = float3(0.003);  // #0A0A0A, the unlit room

// The lamp's radiance seen in a reflection, against the light it gives the floor under it, and the
// bright core of its disc that the metal mirrors, as a share of its radius.
constant float lampGlow      = 1.8;
constant float lampCoreShare = 1.0;

// The sphere's metal: GGX roughness, how much of its tint it reflects head on, the shares of the
// room the precomputed path shows on it, and how much of the painted body's own light a metal keeps.
constant float metalRoughness   = 0.24;
constant float metalReflectance = 0.9;
constant float sheenShare       = 0.2;   // the precomputed estimate of the floor on the metal
constant float rimShare         = 0.6;   // the precomputed estimate of the walls at the silhouette
constant float bodyDiffuse      = 0.6;

// The metal reflects for the room's camera, straight down: its centre looks up at the lamp, its
// silhouette sideways into the walls, the ring between down onto the floor beside it.
constant float3 sphereView = float3(0, 0, 1);

// Where the metal sees the lamp's glow, from the lamp, as fractions of the room's short side: north-
// west and a little lower, so the soft reflection sits upper left, as MascotLayer's sheen does.
// Moving the lamp itself there threw a long hard shadow across the room, so only the reflection
// takes this offset, as MascotLayer's sheen follows a key light of its own.
constant float3 glowOffset = float3(-0.45, -0.6, -0.25);

// Points on the lamp the precomputed shadow tests, on the floor and walls seen directly, and where
// it estimates bounces and the room's sheen on the sphere.
constant uint occlusionSamples  = 32;
constant uint reflectionSamples = 6;

// Ray-traced sampling: frames accumulated per change, shadow rays per frame, ambient occlusion reach.
constant uint  accumulatedFrames = 64;
constant uint  shadowRays        = 2;
constant uint  glossRays         = 4;     // reflection rays per frame on the sphere
constant float backdropRise      = 3;     // how high the walls seem to rise in the metal
constant float backdropGlow      = 3;     // how much more light the risen walls catch
constant float occlusionReach    = 0.25;  // of the short side
// The share of the lamp's light that ambient occlusion also takes, in corners and at walls' foot.
constant float occlusionLightShare = 0.35;

// Geometry ids in the acceleration structure: the room is 0.
constant uint sphereGeometry = 1;

struct Room {
    float2 size;
    float  side;
    float  wallHeight;
    float  wallReach;
    float  cornerRadius;
    float3 sphere;
    float  radius;
    float3 lamp;
    float  lampRadius;
    float3 light;        // linear colour times strength and exposure
    float3 lightSRGB;
    float  strength;
    float3 tint;
    float3 metal;        // linear reflectance of the sphere head on
    bool   isOccupied;
    float  pointsPerPixel;
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

/// Keeps radiance up to 0.5 as it is, so the authored sphere keeps its colours, and rolls the rest
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

static Room makeRoom(constant RoomLightUniforms& uniforms) {
    Room room;
    room.size           = uniforms.room.xy;
    room.side           = min(room.size.x, room.size.y);
    room.wallHeight     = uniforms.shape.x;
    room.wallReach      = uniforms.shape.y;
    room.radius         = uniforms.shape.z;
    room.cornerRadius   = uniforms.shape.w;
    room.sphere         = float3(room.size * 0.5, room.radius);
    room.lamp           = float3(poolCentre * room.size, lampHeightShare * room.side);
    room.lampRadius     = lampRadiusShare * room.side;
    room.strength       = uniforms.light.w;
    room.lightSRGB      = uniforms.light.rgb;
    room.light          = linearFromSRGB(uniforms.light.rgb) * uniforms.light.w * exposure;
    room.tint           = uniforms.tint.rgb;
    // The metal keeps the tint's hue at full brightness, half white, so it colours what it reflects
    // without swallowing a light of another hue.
    float brightest     = max(max(room.tint.r, room.tint.g), max(room.tint.b, 0.05));
    room.metal          = mix(float3(0.5), linearFromSRGB(room.tint / brightest), 0.7) * metalReflectance;
    room.isOccupied     = uniforms.tint.w > 0.5;
    room.pointsPerPixel = uniforms.room.z;
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

/// The lamp's pool at a point of the room, 1 at its centre. The core falls off like the prototype's
/// gradient; the tail is the lamp's side light, which the walls catch `wallCatch` times more than
/// the floor, so they read as a lit rim.
static float pool(float2 xy, float wallShare, Room room) {
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

/// The share of the lamp the sphere hides from `position`, over a spiral of points on the lamp's
/// disc: each counts as hidden by how deep its line to `position` passes inside the sphere, softened
/// over a tenth of the radius, so the penumbra has no steps.
static float sphereOcclusion(float3 position, uint samples, Room room) {
    if (!room.isOccupied) { return 0; }
    float hidden = 0;
    for (uint index = 0; index < samples; index++) {
        float  radius    = room.lampRadius * sqrt((index + 0.5) / samples);
        float  angle     = 2 * M_PI_F * fract(index * 0.618034);
        float3 lampPoint = room.lamp + float3(radius * cos(angle), radius * sin(angle), 0);
        float3 line      = lampPoint - position;
        float  along     = clamp(dot(room.sphere - position, line) / dot(line, line), 0.0, 1.0);
        float  miss      = length(position + line * along - room.sphere);
        hidden += 1 - smoothstep(0.9 * room.radius, 1.1 * room.radius, miss);
    }
    return hidden / samples;
}

/// The sky the sphere hides from a floor or wall point, for the ambient light.
static float sphereAmbientOcclusion(Surface surface, Room room) {
    if (!room.isOccupied) { return 0; }
    float3 toSphere = room.sphere - surface.position;
    float  distance = length(toSphere);
    return saturate(dot(surface.normal, toSphere / distance)) * square(room.radius / max(distance, room.radius));
}

// MARK: - The sphere, after MascotLayer

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

static float luminance(float3 c) {
    return dot(c, float3(0.3, 0.59, 0.11));
}

/// The colour blend mode: the tint's hue and saturation with the backdrop's luminance.
static float3 colorBlend(float3 backdrop, float3 source) {
    float3 c  = source + (luminance(backdrop) - luminance(source));
    float  l  = luminance(c);
    float  lo = min(c.r, min(c.g, c.b));
    float  hi = max(c.r, max(c.g, c.b));
    if (lo < 0) { c = l + (c - l) * l / (l - lo); }
    if (hi > 1) { c = l + (c - l) * (1 - l) / (hi - l); }
    return c;
}

/// The sphere's own body in linear light at `uv`, its unit square with y down, layered as
/// MascotLayer layers it: the dark radial base, the tint and the darker lower half, with no painted
/// highlight, since the lamp's reflection is the sphere's only one. A worker that is off is grey and
/// dimmed. It belongs to the base image: it never pulses.
static float3 sphereBody(float2 uv, Room room) {
    bool   isOff = room.strength <= 0;
    float  t     = gradientPosition(uv, float2(0.37, 0.30), float2(0.942));
    float3 color = t <= 0.44 ? mix(hexColor(0x343230), hexColor(0x262423), t / 0.44)
                             : mix(hexColor(0x262423), hexColor(0x232120), saturate((t - 0.44) / 0.56));
    if (!isOff) {
        float tintAlpha = stops3(t, float3(0, 0.5, 1), float3(0.55, 0.28, 0.10));
        color = mix(color, colorBlend(color, room.tint), tintAlpha);
    }
    // Metal has little diffuse light of its own: the painted body is dimmed, the reflections carry it.
    color *= bodyDiffuse;
    // The darker lower half, lighter at the edge than MascotLayer's, so the rim reads lit by the room.
    float shade = stops3(gradientPosition(uv, float2(0.5, 0.25), float2(0.85)), float3(0.55, 0.775, 1), float3(0, 0.12, 0.2));
    color = mix(color, float3(0), shade);
    return linearFromSRGB(isOff ? color * 0.45 : color);
}

/// The crescent of room light inside the bottom of the outline, MascotLayer's bounce, wide and faint
/// with a long soft falloff.
static float3 sphereBounce(float2 uv, Room room) {
    float alpha = 0.1 * exp(-square(gradientPosition(uv, float2(0.5, 1.2), float2(1.4, 0.9)) / 0.4));
    return alpha * linearFromSRGB(room.lightSRGB) * room.strength;
}

/// The sphere's normal under `xy`, seen from above.
static float3 sphereNormal(float2 xy, Room room) {
    float2 disc = (xy - room.sphere.xy) / room.radius;
    disc       /= max(1.0, length(disc));
    return float3(disc, sqrt(saturate(1 - dot(disc, disc))));
}

/// The metal's reflectance at `cosine` between the facet and the viewer: its tint head on, white at
/// grazing angles.
static float3 metalFresnel(float cosine, Room room) {
    return room.metal + (1 - room.metal) * pow(1 - saturate(cosine), 5.0);
}

/// The unit square coordinate of a point seen from above, in the sphere's bounding square.
static float2 sphereUV(float2 xy, Room room) {
    return (xy - (room.sphere.xy - room.radius)) / (2 * room.radius);
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

/// The lamp mirrored by the sphere's metal at `normal`: the lamp's soft core seen through the
/// metal's gloss, a lobe around the mirror direction as wide as the two together, so the highlight
/// is smooth at any size. Nothing stands between the sphere and the lamp above it, so both paths
/// evaluate it the same way, without tracing.
static float3 lampHighlight(float3 normal, Room room) {
    float3 origin   = room.sphere + normal * room.radius;
    float3 toLamp   = room.lamp + glowOffset * room.side - origin;
    float  distance = length(toLamp);
    float3 mirrored = reflect(-sphereView, normal);
    float  apart    = acos(clamp(dot(mirrored, toLamp / distance), -1.0, 1.0));
    float  core     = atan(lampCoreShare * room.lampRadius / distance);
    float  gloss    = 1.2 * metalRoughness;
    float  spread   = core * core + gloss * gloss;
    float  facing   = saturate(4 * dot(normal, toLamp / distance));
    float3 halfway  = normalize(sphereView + toLamp / distance);
    return lampGlow * room.light * (core * core / spread) * exp(-apart * apart / spread)
         * metalFresnel(dot(halfway, sphereView), room) * facing;
}

// MARK: - Precomputed light

/// The light alone at a floor or wall point: the lamp with an analytic soft shadow tested against
/// `samples` points of the lamp, and the light floor and walls bounce to each other, estimated where
/// the nearest wall meets the floor.
static float3 analyticLight(float2 xy, uint samples, Room room) {
    Surface surface = surfaceAt(xy, room);
    float3  direct  = surface.albedo * lampTerm(surface.position, surface.normal, room.lamp, room)
                    * (1 - sphereOcclusion(surface.position, samples, room)) * room.light;

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
                      * (1 - sphereOcclusion(floor.position, reflectionSamples, room)) * rise;
    return direct + surface.albedo * (0.08 * fromWall + 0.45 * fromFloor) * room.light;
}

/// The room's light on the sphere's metal, estimated without tracing, for the camera straight down:
/// the ring between the top and the silhouette sees the floor beside the sphere, the silhouette the
/// wall in the same direction, each as a smooth wash of the light found there, weakened by
/// `sheenShare` and `rimShare`. The ray tracer reflects the room itself instead.
static float3 roomSheen(float3 normal, Room room) {
    float  across   = length(normal.xy);
    float2 outward  = normal.xy / max(across, 1e-4);
    float2 toEdges  = select(room.sphere.xy, room.size - room.sphere.xy, outward > 0) / max(abs(outward), 1e-4);
    float  toWall   = min(toEdges.x, toEdges.y) - 0.5 * room.wallReach;
    float3 wall     = analyticLight(room.sphere.xy + outward * toWall, reflectionSamples, room);
    float3 floor    = analyticLight(room.sphere.xy + outward * 1.8 * room.radius, reflectionSamples, room);
    float  ring     = smoothstep(0.55, 0.85, across) * (1 - smoothstep(0.8, 1.0, across));
    float  rim      = smoothstep(0.75, 1.0, across);
    return metalFresnel(normal.z, room) * (ring * floor * sheenShare + rim * wall * rimShare);
}

kernel void precomputeRoom(texture2d<float, access::write> base     [[texture(0)]],
                           texture2d<float, access::write> light    [[texture(1)]],
                           constant RoomLightUniforms&     uniforms [[buffer(0)]],
                           uint2                           pixel    [[thread_position_in_grid]])
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room    room    = makeRoom(uniforms);
    float2  xy      = (float2(pixel) + 0.5) * room.pointsPerPixel;
    Surface surface = surfaceAt(xy, room);
    Images  images  = { ambient * (1 - sphereAmbientOcclusion(surface, room)), analyticLight(xy, occlusionSamples, room) };

    if (room.isOccupied) {
        float distance = length(xy - room.sphere.xy);
        float coverage = saturate((room.radius - distance) / room.pointsPerPixel + 0.5);
        if (coverage > 0) {
            float2 uv        = sphereUV(xy, room);
            float3 normal    = sphereNormal(xy, room);
            float3 reflected = roomSheen(normal, room) + lampHighlight(normal, room);
            images.base  = mix(images.base, sphereBody(uv, room), coverage);
            images.light = mix(images.light, reflected + sphereBounce(uv, room), coverage);
        }
    }
    base.write(float4(images.base, 1), pixel);
    light.write(float4(images.light, 1), pixel);
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

/// The floor or wall a ray hit, or false for the sphere or nothing.
static bool hitRoom(intersection_result<> hit, ray traced, Room room, thread Surface& surface) {
    if (hit.type == intersection_type::none || hit.geometry_id == sphereGeometry) { return false; }
    float3 position = traced.origin + traced.direction * hit.distance;
    surface = surfaceAt(position.xy, room);
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

/// The walls' glow a reflection ray meets above their top. The walls are low beside the sphere, so
/// the metal sees them as rising on, brighter toward the lamp and fading out by `backdropRise` times
/// their height: the room's lit rim reflected on the sphere's flanks, as in a taller room.
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

/// One frame of the sphere under `xy`: its body, the lamp mirrored by its metal, the room reflected
/// through `glossRays` traced GGX facets with their shadows, and the crescent of room light at the
/// bottom.
static Images tracedSphere(float2 xy, primitive_acceleration_structure scene, Room room, Frame frame, thread uint& seed) {
    float2 uv     = sphereUV(xy, room);
    float3 normal = sphereNormal(xy, room);
    float3 origin = room.sphere + normal * room.radius * 1.001;
    Images images = { sphereBody(uv, room), sphereBounce(uv, room) + lampHighlight(normal, room) };

    const float total = accumulatedFrames * glossRays;
    for (uint index = 0; index < glossRays; index++) {
        float  number   = frame.index * glossRays + index;
        float2 sample   = float2((number + random(seed)) / total, fract(number * 0.618034 + frame.rotation.y));
        float3 facet    = facetSample(normal, metalRoughness, sample);
        float3 mirrored = reflect(-sphereView, facet);
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
        images.light += metalFresnel(dot(facet, sphereView), room) * seen / glossRays;
    }
    return images;
}

kernel void traceRoom(texture2d<float, access::write>  base     [[texture(0)]],
                      texture2d<float, access::write>  light    [[texture(1)]],
                      constant RoomLightUniforms&      uniforms [[buffer(0)]],
                      primitive_acceleration_structure scene    [[buffer(1)]],
                      uint2                            pixel    [[thread_position_in_grid]])
{
    if (pixel.x >= base.get_width() || pixel.y >= base.get_height()) { return; }
    Room   room     = makeRoom(uniforms);
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
            images = tracedRoom(surface, scene, room, frame, seed);
        } else if (hit.type != intersection_type::none) {
            images = tracedSphere(xy, scene, room, frame, seed);
        } else {
            // Outside the rounded outline, which the view's corners clip: the top of the wall.
            Surface rim = surfaceAt(xy, room);
            images.base  = ambient;
            images.light = rim.albedo * lampTerm(rim.position, rim.normal, room.lamp, room) * room.light;
        }
        sum.base  += images.base;
        sum.light += images.light;
    }
    base.write(float4(sum.base / accumulatedFrames, 1), pixel);
    light.write(float4(sum.light / accumulatedFrames, 1), pixel);
}
