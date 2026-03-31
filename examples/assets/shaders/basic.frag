#version 330 core
#include "common.glsl"

uniform sampler2D u_albedo;
uniform sampler2D u_normal_map;
uniform vec3 u_light_dir;
uniform vec3 u_light_color;
uniform float u_roughness;

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
