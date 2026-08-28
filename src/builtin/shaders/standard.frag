#version 330 core
// VARIANTS: ALPHA_TEST, ALPHA_BLEND, DOUBLE_SIDED, HAS_ALBEDO_MAP, HAS_NORMAL_MAP, HAS_AO, HAS_EMISSIVE, HAS_METALLIC_ROUGHNESS_MAP

in vec3 v_world_pos;
in vec3 v_normal;
in vec4 v_tangent;
in vec2 v_uv0;

// --- Texture slots. Names must match textureResourceName() in material_generator.zig.
uniform sampler2D u_albedo;
uniform sampler2D u_normal_map;
uniform sampler2D u_roughness_metallic_map;
uniform sampler2D u_ao_map;
uniform sampler2D u_emissive_map;

// --- Per-slot UV transforms (KHR_texture_transform). Identity until Phase 2.
//     xy = scale, zw = offset. Rotation is folded in by the CPU side.
uniform vec4 u_albedo_uv_transform;
uniform vec4 u_normal_uv_transform;
uniform vec4 u_orm_uv_transform;
uniform vec4 u_ao_uv_transform;
uniform vec4 u_emissive_uv_transform;

// --- Material params.
uniform vec4 u_base_color;
uniform float u_metallic;
uniform float u_roughness;
uniform vec3 u_emissive;
uniform vec2 u_uv_scale;
uniform float u_normal_scale;
uniform float u_occlusion_strength;
uniform float u_alpha_cutoff;

// --- Frame constants.
uniform vec3 u_camera_pos;

out vec4 FragColor;

const float PI = 3.14159265359;

// Default studio rig: key / fill / rim. Replaced by real light components later;
// until then a model must look correct the moment it is dropped into a scene.
// Directions point *from* the light. Kept unnormalized — normalize() is not a
// constant expression in GLSL 330, so it happens at use.
const vec3 LIGHT_DIR[3] = vec3[3](
    vec3(-0.32, -0.79, -0.52),
    vec3(0.79, -0.28, 0.45),
    vec3(0.10, 0.60, 0.79)
  );
const vec3 LIGHT_COLOR[3] = vec3[3](
    vec3(3.20, 3.10, 2.94),
    vec3(0.65, 0.72, 0.86),
    vec3(0.57, 0.55, 0.53)
  );
const vec3 AMBIENT = vec3(0.16, 0.18, 0.22);

vec2 applyTransform(vec2 uv, vec4 xform) {
  return uv * xform.xy + xform.zw;
}

// ---------------------------------------------------------------- BRDF

float distributionGGX(vec3 N, vec3 H, float roughness) {
  float a = roughness * roughness;
  float a2 = a * a;
  float NdotH = max(dot(N, H), 0.0);
  float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
  return a2 / max(PI * d * d, 1e-7);
}

float geometrySchlickGGX(float NdotX, float roughness) {
  float r = roughness + 1.0;
  float k = (r * r) / 8.0;
  return NdotX / (NdotX * (1.0 - k) + k);
}

float geometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
  return geometrySchlickGGX(max(dot(N, V), 0.0), roughness)
    * geometrySchlickGGX(max(dot(N, L), 0.0), roughness);
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
  return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Screen-space TBN for meshes that ship no tangent stream.
mat3 cotangentFrame(vec3 N, vec3 p, vec2 uv) {
  vec3 dp1 = dFdx(p), dp2 = dFdy(p);
  vec2 du1 = dFdx(uv), du2 = dFdy(uv);

  vec3 dp2perp = cross(dp2, N);
  vec3 dp1perp = cross(N, dp1);
  vec3 T = dp2perp * du1.x + dp1perp * du2.x;
  vec3 B = dp2perp * du1.y + dp1perp * du2.y;

  float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
  return mat3(T * invmax, B * invmax, N);
}

vec3 tonemapACES(vec3 x) {
  const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
  vec2 uv = v_uv0 * u_uv_scale;

  vec4 base = u_base_color;
  #ifdef HAS_ALBEDO_MAP
  base *= texture(u_albedo, applyTransform(uv, u_albedo_uv_transform));
  #endif

  #ifdef ALPHA_TEST
  if (base.a < u_alpha_cutoff) discard;
  #endif

  float metallic = u_metallic;
  float roughness = u_roughness;
  float ao = 1.0;

  #ifdef HAS_METALLIC_ROUGHNESS_MAP
  // glTF packing: R = occlusion (ORM only), G = roughness, B = metallic.
  vec3 orm = texture(u_roughness_metallic_map, applyTransform(uv, u_orm_uv_transform)).rgb;
  roughness *= orm.g;
  metallic *= orm.b;
  #endif

  #ifdef HAS_AO
  #ifdef HAS_METALLIC_ROUGHNESS_MAP
  ao = mix(1.0, orm.r, u_occlusion_strength);
  #else
  ao = mix(1.0, texture(u_ao_map, applyTransform(uv, u_ao_uv_transform)).r, u_occlusion_strength);
  #endif
  #endif

  // Clamp away the mirror singularity that makes GGX produce fireflies.
  roughness = clamp(roughness, 0.045, 1.0);

  vec3 N = normalize(v_normal);
  #ifdef DOUBLE_SIDED
  if (!gl_FrontFacing) N = -N;
  #endif

  #ifdef HAS_NORMAL_MAP
  vec2 nuv = applyTransform(uv, u_normal_uv_transform);
  vec3 tn = texture(u_normal_map, nuv).xyz * 2.0 - 1.0;
  tn.xy *= u_normal_scale;

  mat3 TBN;
  if (abs(v_tangent.w) > 0.5) {
    // Gram-Schmidt against the interpolated normal; w carries handedness.
    vec3 T = normalize(v_tangent.xyz - N * dot(N, v_tangent.xyz));
    TBN = mat3(T, cross(N, T) * v_tangent.w, N);
  } else {
    TBN = cotangentFrame(N, v_world_pos, nuv);
  }
  N = normalize(TBN * tn);
  #endif

  vec3 V = normalize(u_camera_pos - v_world_pos);
  vec3 F0 = mix(vec3(0.04), base.rgb, metallic);
  vec3 diffuse_color = base.rgb * (1.0 - metallic);

  vec3 Lo = vec3(0.0);
  for (int i = 0; i < 3; ++i) {
    vec3 L = normalize(-LIGHT_DIR[i]);
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) continue;

    vec3 H = normalize(V + L);
    float NDF = distributionGGX(N, H, roughness);
    float G = geometrySmith(N, V, L, roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

    vec3 specular = (NDF * G * F)
        / max(4.0 * max(dot(N, V), 0.0) * NdotL, 1e-4);
    vec3 kD = vec3(1.0) - F;

    Lo += (kD * diffuse_color / PI + specular) * LIGHT_COLOR[i] * NdotL;
  }

  vec3 emissive = u_emissive;
  #ifdef HAS_EMISSIVE
  emissive *= texture(u_emissive_map, applyTransform(uv, u_emissive_uv_transform)).rgb;
  #endif

  vec3 color = Lo * ao + AMBIENT * diffuse_color * ao + emissive;
  color = tonemapACES(color);
  color = pow(color, vec3(1.0 / 2.2));

  FragColor = vec4(color, base.a);
}
