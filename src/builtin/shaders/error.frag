#version 330 core
in vec3 v_object_pos;
out vec4 FragColor;

void main() {
  vec3 s = floor(v_object_pos * 6.0);
  float checker = mod(s.x + s.y + s.z, 2.0);
  vec3 color = mix(vec3(1.0, 0.0, 0.85), vec3(0.10, 0.0, 0.09), checker);
  FragColor = vec4(color, 1.0);
}
