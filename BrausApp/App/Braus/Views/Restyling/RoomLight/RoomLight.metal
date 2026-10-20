//
//  RoomLight.metal
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

// A room seen straight from above, orthographic: a floor, four low walls that lean outward so their
// faces show from above, and the worker as a sphere at the centre resting on the floor. A disc light
// just above the sphere, facing down, lights the room in the worker's status colour. Scene units are
// points: x to the right, y down as on screen, z up from the floor.
//
// `traceRoom` traces the scene against an acceleration structure; `precomputeRoom` evaluates the
// same scene analytically. Both share the room's geometry, its light and the sphere's look.

#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace raytracing;

/// RoomLightUniforms matches `RoomLightUniforms.Packed` in Swift: three float4, 48 bytes.
struct RoomLightUniforms {
    float4 light;   // sRGB colour, strength in w
    float4 tint;    // sRGB tint, w is 1 when the worker is in the room
    float4 room;    // width and height in points, points per pixel, unused
};

// The scene's proportions, as fractions of the room's short side.
constant float wallHeightShare  = 0.18;
constant float wallReachShare   = 0.09;  // how far a leaning wall reaches into the room
constant float sphereShare      = 0.17;
constant float lampHeightShare  = 0.62;
constant float lampRadiusShare  = 0.20;
constant float lampShiftShare   = 0.06;  // toward the top of the room, so the shadow falls below

constant float floorAlbedo = 0.5;
constant float wallAlbedo  = 0.8;
constant float exposure    = 0.36;
constant float lampFocus   = 6;     // the lamp shines mostly down, so the light pools under it
constant float3 ambient    = float3(0.003);  // #0A0A0A, the unlit room

// Ray-traced sampling: frames accumulated per change, shadow rays per frame.
constant uint accumulatedFrames = 16;
constant uint shadowRays        = 4;

// Geometry ids in the acceleration structure: the floor is 0.
constant uint wallsGeometry  = 1;
constant uint sphereGeometry = 2;

struct Room {
    float2 size;
    float  wallHeight;
    float  wallReach;
    float3 sphere;
    float  radius;
    float3 lamp;
    float  lampRadius;
    float3 light;        // linear colour times strength and exposure
    float3 lightSRGB;
    float  strength;
    float3 tint;
    bool   isOccupied;
    float  pointsPerPixel;
};

struct Surface {
    float3 position;
    float3 normal;
    float  albedo;
};

static float3 linearFromSRGB(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float3 sRGBFromLinear(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
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
    float side          = min(room.size.x, room.size.y);
    room.wallHeight     = wallHeightShare * side;
    room.wallReach      = wallReachShare * side;
    room.radius         = sphereShare * side;
    room.sphere         = float3(room.size * 0.5, room.radius);
    room.lamp           = float3(room.size.x * 0.5, room.size.y * 0.5 - lampShiftShare * side, lampHeightShare * side);
    room.lampRadius     = lampRadiusShare * side;
    room.strength       = uniforms.light.w;
    room.lightSRGB      = uniforms.light.rgb;
    room.light          = linearFromSRGB(uniforms.light.rgb) * uniforms.light.w * exposure;
    room.tint           = uniforms.tint.rgb;
    room.isOccupied     = uniforms.tint.w > 0.5;
    room.pointsPerPixel = uniforms.room.z;
    return room;
}

/// The inward normal of wall `index`: 0 left, 1 top, 2 right, 3 bottom.
static float3 wallNormal(uint index, Room room) {
    float3 normal;
    switch (index) {
        case 0:  normal = float3( room.wallHeight, 0, room.wallReach); break;
        case 1:  normal = float3(0,  room.wallHeight, room.wallReach); break;
        case 2:  normal = float3(-room.wallHeight, 0, room.wallReach); break;
        default: normal = float3(0, -room.wallHeight, room.wallReach); break;
    }
    return normalize(normal);
}

/// The wall nearest to `xy` (0 left, 1 top, 2 right, 3 bottom) and, in `edge`, the distance to
/// the room's outline.
static uint nearestWall(float2 xy, Room room, thread float& edge) {
    float4 edges = float4(xy.x, xy.y, room.size.x - xy.x, room.size.y - xy.y);
    edge = min(min(edges.x, edges.y), min(edges.z, edges.w));
    return edge == edges.x ? 0 : (edge == edges.y ? 1 : (edge == edges.z ? 2 : 3));
}

/// The floor or wall seen from above at `xy`.
static Surface surfaceAt(float2 xy, Room room) {
    float edge;
    uint  wall = nearestWall(xy, room, edge);
    Surface surface;
    if (edge >= room.wallReach) {
        surface.position = float3(xy, 0);
        surface.normal   = float3(0, 0, 1);
        surface.albedo   = floorAlbedo;
    } else {
        surface.position = float3(xy, room.wallHeight * (1 - max(edge, 0.0) / room.wallReach));
        surface.normal   = wallNormal(wall, room);
        surface.albedo   = wallAlbedo;
    }
    return surface;
}

/// The light a point of the disc lamp at `lampPoint` gives a surface, before its colour and albedo.
/// It is 1 on the floor straight below the lamp.
static float lampTerm(float3 position, float3 normal, float3 lampPoint, Room room) {
    float3 toLamp   = lampPoint - position;
    float  distance2 = dot(toLamp, toLamp);
    float3 direction = toLamp * rsqrt(distance2);
    float  surfaceCos = max(dot(normal, direction), 0.0);
    float  lampCos    = max(direction.z, 0.0);
    return surfaceCos * pow(lampCos, 1 + lampFocus) * room.lamp.z * room.lamp.z / distance2;
}

/// The share of the lamp the sphere hides from `position`: the overlap of the two discs as seen
/// from there, divided by the lamp's.
static float sphereOcclusion(float3 position, Room room) {
    if (!room.isOccupied) { return 0; }
    float3 toLamp   = room.lamp - position;
    float3 toSphere = room.sphere - position;
    float  lampDistance   = length(toLamp);
    float  sphereDistance = length(toSphere);
    if (sphereDistance <= room.radius || sphereDistance > lampDistance) { return 0; }
    float lampAngle   = atan(room.lampRadius / lampDistance);
    float sphereAngle = asin(room.radius / sphereDistance);
    float apart       = acos(clamp(dot(toLamp / lampDistance, toSphere / sphereDistance), -1.0, 1.0));
    if (apart >= lampAngle + sphereAngle) { return 0; }
    if (apart <= abs(lampAngle - sphereAngle)) {
        float smaller = min(lampAngle, sphereAngle);
        return smaller * smaller / (lampAngle * lampAngle);
    }
    float a = lampAngle, b = sphereAngle, d = apart;
    float lens = a * a * acos(clamp((d * d + a * a - b * b) / (2 * d * a), -1.0, 1.0))
               + b * b * acos(clamp((d * d + b * b - a * a) / (2 * d * b), -1.0, 1.0))
               - 0.5 * sqrt(max((-d + a + b) * (d + a - b) * (d - a + b) * (d + a + b), 0.0));
    return saturate(lens / (M_PI_F * a * a));
}

/// The radiance of a floor or wall point lit straight from the lamp, without shadow.
static float3 directLight(Surface surface, Room room) {
    return surface.albedo * lampTerm(surface.position, surface.normal, room.lamp, room) * room.light;
}

/// Compresses radiance into 0...1 while keeping the dark range as it is.
static float3 toneMap(float3 radiance) {
    return 1 - exp(-radiance);
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

/// The sphere's body in sRGB at `uv`, its unit square with y down, layered as MascotLayer layers
/// it: the dark radial base, the tint, the darker lower half, the crescent of room light at the
/// bottom and the white highlight. A worker that is off is grey and dimmed.
static float3 sphereBody(float2 uv, Room room) {
    bool isOff = room.strength <= 0;

    float  t    = gradientPosition(uv, float2(0.37, 0.30), float2(0.942));
    float3 dark = t <= 0.44 ? mix(hexColor(0x343230), hexColor(0x262423), t / 0.44)
                            : mix(hexColor(0x262423), hexColor(0x141313), saturate((t - 0.44) / 0.56));
    float3 color = dark;
    if (!isOff) {
        float tintAlpha = stops3(t, float3(0, 0.5, 1), float3(0.55, 0.28, 0.10));
        color = mix(color, colorBlend(color, room.tint), tintAlpha);
    }

    float shade = stops3(gradientPosition(uv, float2(0.5, 0.25), float2(0.85)), float3(0.55, 0.775, 1), float3(0, 0.275, 0.55));
    color = mix(color, float3(0), shade);

    float bounce = stops3(gradientPosition(uv, float2(0.5, 1.1), float2(1.0, 0.6)), float3(0, 0.2, 0.34), float3(0.6, 0.35, 0)) * room.strength;
    color = mix(color, room.lightSRGB, bounce);

    float highlight = stops3(gradientPosition(uv, float2(0.31, 0.13), float2(1.0, 0.8)), float3(0, 0.025, 0.06), float3(0.9, 0.5, 0));
    color = mix(color, float3(1), highlight);

    return isOff ? color * 0.45 : color;
}

/// The sphere's unit square coordinate of a point seen from above.
static float2 sphereUV(float2 xy, Room room) {
    return (xy - (room.sphere.xy - room.radius)) / (2 * room.radius);
}

/// The sphere's normal under `xy`, seen from above.
static float3 sphereNormal(float2 xy, Room room) {
    float2 flat = (xy - room.sphere.xy) / room.radius;
    return float3(flat, sqrt(saturate(1 - dot(flat, flat))));
}

/// How much the dark, glossy sphere reflects where its normal tilts by `cosine` from the viewer.
static float fresnel(float cosine) {
    return 0.04 + 0.96 * pow(1 - saturate(cosine), 5.0);
}

// MARK: - Precomputed light

/// The floor or wall radiance with an analytic soft shadow and an estimate of the light bounced
/// between floor and walls, taken where the nearest wall meets the floor.
static float3 analyticRadiance(float2 xy, Room room) {
    Surface surface = surfaceAt(xy, room);
    float3  lit     = directLight(surface, room) * (1 - sphereOcclusion(surface.position, room));

    float  edge;
    uint   wall = nearestWall(xy, room, edge);
    float2 foot = xy;
    switch (wall) {
        case 0:  foot.x = room.wallReach; break;
        case 1:  foot.y = room.wallReach; break;
        case 2:  foot.x = room.size.x - room.wallReach; break;
        default: foot.y = room.size.y - room.wallReach; break;
    }
    Surface seam;
    seam.position = float3(foot, 0);
    float3 bounce;
    if (edge < room.wallReach) {
        // A wall takes the light of the floor below it, less toward its top.
        seam.normal = float3(0, 0, 1);
        seam.albedo = floorAlbedo;
        float height = surface.position.z / room.wallHeight;
        bounce = directLight(seam, room) * (1 - sphereOcclusion(seam.position, room)) * 0.45 * (1 - 0.5 * height);
    } else {
        // The floor takes the colour of the nearest wall, fading away from it.
        seam.normal = wallNormal(wall, room);
        seam.albedo = wallAlbedo;
        bounce = directLight(seam, room) * 0.25 * exp(-(edge - room.wallReach) / room.wallReach);
    }
    return ambient + lit + surface.albedo * bounce;
}

kernel void precomputeRoom(texture2d<float, access::write> output   [[texture(0)]],
                           constant RoomLightUniforms&     uniforms [[buffer(0)]],
                           uint2                           pixel    [[thread_position_in_grid]])
{
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) { return; }
    Room   room  = makeRoom(uniforms);
    float2 xy    = (float2(pixel) + 0.5) * room.pointsPerPixel;
    float3 color = toneMap(analyticRadiance(xy, room));

    if (room.isOccupied) {
        float distance = length(xy - room.sphere.xy);
        float coverage = saturate((room.radius - distance) / room.pointsPerPixel + 0.5);
        if (coverage > 0) {
            float3 normal     = sphereNormal(xy, room);
            float3 reflection = reflect(float3(0, 0, -1), normal);
            float3 reflected  = float3(0);
            if (reflection.z < 0) {
                float3 start = float3(xy, room.radius * (1 + normal.z));
                float3 hit   = start + reflection * (start.z / -reflection.z);
                float2 seen  = clamp(hit.xy, float2(0), room.size);
                reflected = toneMap(analyticRadiance(seen, room));
            }
            float3 body = linearFromSRGB(sphereBody(sphereUV(xy, room), room)) + fresnel(normal.z) * reflected;
            color = mix(color, body, coverage);
        }
    }
    output.write(encodedPixel(color, pixel), pixel);
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
    float  radius  = sqrt(sample.x);
    float  angle   = 2 * M_PI_F * sample.y;
    float3 helper  = abs(normal.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 tangent = normalize(cross(helper, normal));
    float3 other   = cross(normal, tangent);
    return normalize(tangent * radius * cos(angle) + other * radius * sin(angle) + normal * sqrt(max(0.0, 1 - radius * radius)));
}

/// Whether nothing stands between `position` and `lampPoint`.
static bool sees(float3 position, float3 normal, float3 lampPoint, primitive_acceleration_structure scene, Room room) {
    float3 start  = position + normal * room.wallHeight * 1e-3;
    float3 toLamp = lampPoint - start;
    float  span   = length(toLamp);
    intersector<> shadows;
    shadows.assume_geometry_type(geometry_type::triangle);
    shadows.force_opacity(forced_opacity::opaque);
    shadows.accept_any_intersection(true);
    ray shadow(start, toLamp / span, 0, span);
    return shadows.intersect(shadow, scene).type == intersection_type::none;
}

/// The surface a ray hit, or false for the sphere or nothing.
static bool hitSurface(intersection_result<> hit, ray traced, Room room, thread Surface& surface) {
    if (hit.type == intersection_type::none || hit.geometry_id == sphereGeometry) { return false; }
    surface.position = traced.origin + traced.direction * hit.distance;
    if (hit.geometry_id == wallsGeometry) {
        surface.normal = wallNormal(hit.primitive_id / 2, room);
        surface.albedo = wallAlbedo;
    } else {
        surface.normal = float3(0, 0, 1);
        surface.albedo = floorAlbedo;
    }
    return true;
}

/// Frame is one of the accumulated frames of a pixel: its index, and the pixel's own rotation of
/// the sample patterns, so neighbouring pixels do not repeat each other's noise.
struct Frame {
    uint   index;
    float2 rotation;
};

/// One frame of a floor or wall point: shadow rays to the lamp and one bounce. Across the frames the
/// shadow rays cover the disc as a spiral and the bounces cover the hemisphere in strata.
static float3 tracedRadiance(Surface surface, primitive_acceleration_structure scene, Room room, Frame frame, thread uint& seed) {
    const float samples = accumulatedFrames * shadowRays;
    float direct = 0;
    for (uint index = 0; index < shadowRays; index++) {
        float  number    = frame.index * shadowRays + index;
        float3 lampPoint = lampSample(room, float2((number + 0.5) / samples, fract(number * 0.618034 + frame.rotation.x)));
        if (sees(surface.position, surface.normal, lampPoint, scene, room)) {
            direct += lampTerm(surface.position, surface.normal, lampPoint, room);
        }
    }
    float3 radiance = surface.albedo * direct / shadowRays * room.light;

    intersector<> nearest;
    nearest.assume_geometry_type(geometry_type::triangle);
    nearest.force_opacity(forced_opacity::opaque);
    float2 stratum = float2(frame.index % 4, frame.index / 4);
    float2 sample  = fract((stratum + float2(random(seed), random(seed))) / 4 + frame.rotation);
    ray    bounce(surface.position + surface.normal * room.wallHeight * 1e-3, cosineSample(surface.normal, sample));
    Surface other;
    if (hitSurface(nearest.intersect(bounce, scene), bounce, room, other)) {
        float3 lampPoint = lampSample(room, float2(random(seed), random(seed)));
        if (sees(other.position, other.normal, lampPoint, scene, room)) {
            radiance += surface.albedo * other.albedo * lampTerm(other.position, other.normal, lampPoint, room) * room.light;
        }
    }
    return ambient + radiance;
}

kernel void traceRoom(texture2d<float, access::write>  output   [[texture(0)]],
                      constant RoomLightUniforms&      uniforms [[buffer(0)]],
                      primitive_acceleration_structure scene    [[buffer(1)]],
                      uint2                            pixel    [[thread_position_in_grid]])
{
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) { return; }
    Room room = makeRoom(uniforms);
    uint seed = pcg(pixel.x + pcg(pixel.y));
    float top = room.wallHeight * 4 + room.radius * 4;

    intersector<> nearest;
    nearest.assume_geometry_type(geometry_type::triangle);
    nearest.force_opacity(forced_opacity::opaque);

    float2 rotation = float2(random(seed), random(seed));
    float3 sum      = 0;
    for (uint index = 0; index < accumulatedFrames; index++) {
        Frame frame = { index, rotation };
        float2 xy = (float2(pixel) + float2(random(seed), random(seed))) * room.pointsPerPixel;
        ray    primary(float3(xy, top), float3(0, 0, -1));
        intersection_result<> hit = nearest.intersect(primary, scene);

        Surface surface;
        if (hitSurface(hit, primary, room, surface)) {
            sum += toneMap(tracedRadiance(surface, scene, room, frame, seed));
        } else if (hit.type != intersection_type::none) {
            float3 position   = primary.origin + primary.direction * hit.distance;
            float3 normal     = normalize(position - room.sphere);
            float3 reflection = reflect(primary.direction, normal);
            ray    mirrored(position + normal * room.radius * 1e-3, reflection);
            Surface seen;
            float3 reflected = float3(0);
            if (hitSurface(nearest.intersect(mirrored, scene), mirrored, room, seen)) {
                reflected = toneMap(tracedRadiance(seen, scene, room, frame, seed));
            }
            sum += linearFromSRGB(sphereBody(sphereUV(xy, room), room)) + fresnel(normal.z) * reflected;
        } else {
            sum += toneMap(ambient);
        }
    }
    output.write(encodedPixel(sum / accumulatedFrames, pixel), pixel);
}
