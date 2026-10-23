#include <metal_stdlib>
using namespace metal;

// Must match PanoRenderer.Uniforms in PanoViewer.swift (64 bytes).
struct Uniforms {
    float3x3 viewToWorld;   // view frame: x right, y up, looking down -z
    float2 tanHalf;         // half-extent of the image plane at z = -1
    float projection;       // 0 = rectilinear, 1 = stereographic ("little planet")
    float texHeight;
};

struct VOut {
    float4 position [[position]];
    float2 ndc;
};

// One triangle that covers the screen.
vertex VOut panoVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.ndc = p * 2.0 - 1.0;
    o.position = float4(o.ndc, 0.0, 1.0);
    return o;
}

// Each pixel becomes a ray: project from a point `projection` units behind the sphere's centre
// through the image plane onto the unit sphere (0 gives a pinhole view, 1 a stereographic one),
// then look the ray up in the equirectangular texture.
fragment float4 panoFragment(VOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]]) {
    float2 q = in.ndc * u.tanHalf;
    float d = u.projection;
    float3 C = float3(0.0, 0.0, d);
    float3 D = float3(q, -1.0 - d);
    float a = dot(D, D);
    float b = dot(C, D);
    float c = d * d - 1.0;
    float t = (-b + sqrt(max(b * b - a * c, 0.0))) / a;
    float3 dir = u.viewToWorld * normalize(C + t * D);

    float lat = asin(clamp(dir.z, -1.0, 1.0));
    float lon = atan2(-dir.y, dir.x);
    float2 uv = float2(lon * (0.5 / M_PI_F) + 0.5, 0.5 - lat / M_PI_F);

    // Mip level from the ray's screen-space change; the texture's u wraps, so its own
    // derivatives would spike along the seam.
    float pix = max(length(dfdx(dir)), length(dfdy(dir)));
    float lod = log2(max(pix * u.texHeight / M_PI_F, 1e-6));
    return float4(tex.sample(s, uv, level(max(lod, 0.0))).rgb, 1.0);
}
