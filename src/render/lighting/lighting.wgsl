#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput
#import bevy_render::view::View

// We're currently only using a single uniform binding for point lights in
// WebGL2, which is limited to 4kb in BatchedUniformBuffer, so we need to
// ensure our point lights can fit in 4kb.
const MAX_POINT_LIGHTS: u32 = 82u;

// Single storage binding for circular occluders.
const MAX_CIRCULAR_OCCLUDERS: u32 = 82u;

// Fraction of a signed distance step to take when raymarching.
const RAYMARCH_STEP: f32 = 0.5;
// Maximum number of steps to take when raymarching.
const MAX_RAYMARCH_STEPS: u32 = 64u;


struct PointLight2d {
    center: vec2f,
    radius: f32,
    color: vec4<f32>,
    intensity: f32,
    falloff: f32
}

struct AmbientLight2d {
    color: vec3<f32>
}

struct CircularOccluder {
    center: vec2<f32>,
    radius: f32,
}

// Coordinate transformations.

fn world_to_ndc(world_position: vec2<f32>, view_projection: mat4x4<f32>) -> vec2<f32> {
    return (view_projection * vec4<f32>(world_position, 0.0, 1.0)).xy;
}

fn ndc_to_screen(ndc: vec2<f32>, screen_size: vec2<f32>) -> vec2<f32> {
    let screen_position: vec2<f32> = (ndc + 1.0) * 0.5 * screen_size;
    return vec2(screen_position.x, (screen_size.y - screen_position.y));
}

fn world_to_screen(
    world_position: vec2<f32>,
    screen_size: vec2<f32>,
    view_projection: mat4x4<f32>
) -> vec2<f32> {
    return ndc_to_screen(world_to_ndc(world_position, view_projection), screen_size);
}

fn scale_factor(view: View) -> f32 {
    let screen_size =
        2.0 * vec2f(view.inverse_projection[0][0], view.inverse_projection[1][1]);
    return screen_size.y / view.viewport.w;
}

// Signed distance functions.

// Calculate the signed distance from a point to a circle
fn signedDistanceCircle(point_pos: vec2f, radius: f32) -> f32 {
  return length(point_pos) - radius;
}


@group(0) @binding(0)
var screen_texture: texture_2d<f32>;

@group(0) @binding(1)
var texture_sampler: sampler;

@group(0) @binding(2)
var<uniform> view: View;

@group(0) @binding(3)
var<uniform> ambient_light: AmbientLight2d;

// WebGL2 does not support storage buffers, so we fall back to a fixed length
// array in a uniform buffer.
#if AVAILABLE_STORAGE_BUFFER_BINDINGS >= 6
    @group(0) @binding(4)
    var<storage> point_lights: array<PointLight2d>;

    @group(0) @binding(5)
    var<storage> circular_occluders: array<CircularOccluder>;
#else
    @group(0) @binding(4)
    var<uniform> point_lights: array<PointLight2d, MAX_POINT_LIGHTS>;

    @group(0) @binding(5)
    var<storage> circular_occluders: array<CircularOccluder, MAX_CIRCULAR_OCCLUDERS>;
#endif

@fragment
fn fragment(vo: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    // Setup aggregate color from light sources to multiply the main texture by.
    var light_color = vec3(1.0);

    // WebGL2 does not support storage buffers (or runtime sized arrays), so we
    // need to use a fixed number of point lights.
#if AVAILABLE_STORAGE_BUFFER_BINDINGS >= 6
    let point_light_count = arrayLength(&point_lights);
#else
    let point_light_count = MAX_POINT_LIGHTS;
#endif

    // For each light, determine its illumination if we're within range of it.
    for (var i = 0u; i < point_light_count; i++) {
        // Get the current point light.
        let point_light = point_lights[i];

        // Our point light position is still in world space. We need to convert
        // it to screen space in order to do things like compute distances (let
        // alone render it in the correct place).
        let point_light_screen_center =
            world_to_screen(point_light.center, view.viewport.zw, view.view_proj);

        // Compute the distance between the current position and the light's center.
        // We multiply by the scale factor as otherwise our distance will always be
        // represented in actual pixels.
        let distance =
            distance(point_light_screen_center, vo.position.xy) * scale_factor(view);

        // If we're within the light's radius, it should provide some level
        // of illumination.
        if distance < point_light.radius {

            // Check if the light is occluded by any circular occluders.
            var occlusion = calculate_occlusion(view, vo.position.xy, point_light_screen_center);

            // Compute light color falloff (a value between 0.0 and 1.0).
            let attenuation = attenuation(
                distance,
                point_light.radius,
                point_light.intensity,
                point_light.falloff
            );

            // Add in the color from the light, taking into account its attenuation.
            light_color += point_light.color.rgb * attenuation * (1.0 - occlusion);
        }
    }

    return textureSample(screen_texture, texture_sampler, vo.uv)
        * vec4(ambient_light.color.rgb, 1.0)
        * vec4(light_color, 1.0);
}

fn square(x: f32) -> f32 {
    return x * x;
}

// Compute light attenutation.
// See https://lisyarus.github.io/blog/posts/point-light-attenuation.html
fn attenuation(distance: f32, radius: f32, intensity: f32, falloff: f32) -> f32 {
    let s = distance / radius;
    if (s > 1.0) {
        return 0.0;
    }
    let s2 = square(s);
    return intensity * square(1 - s2) / (1 + falloff * s2);
}

// Calculate the occlusion of a light source and the occluders in the scene.
// Returns a value between 0.0 and 1.0.
// Returns 0.0 if the light source is not occluded.
// Returns 1.0 if the light source is fully occluded.
fn calculate_occlusion(view: View, fragment_screen_position: vec2<f32>, point_light_screen_center: vec2<f32>) -> f32 {
    #if AVAILABLE_STORAGE_BUFFER_BINDINGS >= 6
        let circular_occluder_count = arrayLength(&circular_occluders);
    #else
        let circular_occluder_count = MAX_CIRCULAR_OCCLUDERS;
    #endif

    var occlusion = 0.0;

    for (var i = 0u; i < circular_occluder_count; i++) {
        let occluder = circular_occluders[i];
        let occluder_screen_center =
            world_to_screen(occluder.center, view.viewport.zw, view.view_proj);

        // Raymarch from the current position to the light source to determine if the light is occluded.
        let shadow_ray_direction = normalize(point_light_screen_center - fragment_screen_position);

        // March along the ray until we reach the light source or the occluder.
        var shadow_ray_progress = 0.0;
        let light_distance = distance(fragment_screen_position, point_light_screen_center) * scale_factor(view);
        for (var j = 0u; j < MAX_RAYMARCH_STEPS; j++) {
            // If the ray has reached the light, we're done.
            if (shadow_ray_progress >= light_distance) {
                break;
            }

            // Determine signed distance to occluder.
            let scene_distance = signedDistanceCircle(
                (fragment_screen_position + (shadow_ray_direction * shadow_ray_progress)) - occluder_screen_center,
                occluder.radius
            ) * scale_factor(view);

            // If the ray has hit the occluder, the light is occluded.
            if scene_distance <= 0.0 {
                occlusion = 1.0;
                break;
            }

            shadow_ray_progress += scene_distance;
        }
    }

    return occlusion;
}