#version 330 core
// VARIANTS: HAS_ALBEDO_MAP, HAS_NORMAL_MAP, HAS_AO, HAS_EMISSIVE, HAS_METALLIC_ROUGHNESS_MAP, ALPHA_TEST, ALPHA_BLEND, DOUBLE_SIDED
#include "common.glsl"

uniform sampler2D u_albedo;
uniform sampler2D u_normal_map;
uniform sampler2D u_roughness_metallic_map;
uniform sampler2D u_ao_map;
uniform sampler2D u_emissive_map;
uniform vec3 u_light_dir;
uniform vec3 u_light_color;
uniform vec4 u_base_color;
uniform float u_metallic;
uniform float u_roughness;
uniform vec3 u_emissive;

in vec3 v_normal;
in vec2 v_uv;
in vec3 v_world_pos;

out vec4 frag_color;

void main() {
    vec3 albedo = texture(u_albedo, v_uv).rgb;
    vec3 normal = normalize(v_normal);
    float ndotl = max(dot(normal, normalize(u_light_dir)), 0.0);
    vec3 ambient = computeAmbient(albedo, 0.1);
    vec3 diffuse = albedo * u_light_color * ndotl;
    frag_color = vec4(ambient + diffuse, 1.0);
}
