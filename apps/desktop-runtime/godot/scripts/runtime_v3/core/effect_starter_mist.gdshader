shader_type canvas_item;
uniform vec4 tint : source_color = vec4(0.2, 0.8, 1.0, 1.0);
uniform float intensity = 0.7;
// Explicit clock lets runtime freeze the effect for reduced motion/resource pressure.
uniform float clock_seconds = 0.0;
varying vec4 vertex_color;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
void vertex() { vertex_color = COLOR; }
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	vec2 drift = vec2(clock_seconds * 0.09, clock_seconds * 0.32);
	float n = noise(p * 4.0 + drift) * 0.65 + noise(p * 9.0 + drift * 1.6) * 0.35;
	float radius = length(p);
	float band = smoothstep(0.28, 0.57, radius) * (1.0 - smoothstep(0.75, 1.0, radius));
	float alpha = band * smoothstep(0.28, 0.8, n) * intensity * 0.65;
	COLOR = vec4(tint.rgb * (0.65 + n * 0.5), alpha) * vertex_color;
}
