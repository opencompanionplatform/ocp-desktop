shader_type canvas_item;
render_mode unshaded;

// Liquid is intentionally restrained: the mock UI uses a soft luminous glass
// surface, not a heavy RGB-split distortion. The effect stays readable behind
// chat text and controls and does not require compositor-specific refraction.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float blur_amount : hint_range(0.0, 8.0) = 2.0;
uniform float warp_intensity : hint_range(0.0, 1.0) = 0.08;
uniform vec4 tint_color : source_color = vec4(0.08, 0.28, 0.48, 0.24);
uniform vec4 border_color : source_color = vec4(0.25, 0.85, 1.0, 0.72);
uniform float corner_radius : hint_range(0.0, 0.5) = 0.10;

float rounded_box(vec2 point, vec2 half_size, float radius) {
	vec2 q = abs(point) - half_size + radius;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void fragment() {
	vec2 centered = UV - vec2(0.5);
	vec2 half_size = vec2(0.5);
	float radius = corner_radius * min(half_size.x, half_size.y);
	float sdf = rounded_box(centered, half_size, radius);
	float alpha = 1.0 - smoothstep(0.0, fwidth(sdf) * 1.5, sdf);
	if (alpha < 0.001) {
		discard;
	}

	float edge = 1.0 - smoothstep(0.0, 0.34, -sdf);
	vec2 direction = length(centered) > 0.001 ? normalize(centered) : vec2(0.0);
	vec2 offset = direction * edge * warp_intensity * SCREEN_PIXEL_SIZE * 18.0;
	vec3 refracted = textureLod(screen_texture, SCREEN_UV - offset, blur_amount).rgb;
	vec3 color = mix(refracted, tint_color.rgb, tint_color.a);

	// A soft diagonal highlight gives the panel its liquid-glass identity
	// without making text shimmer or introducing a distracting RGB split.
	float highlight = smoothstep(0.82, 0.98, 1.0 - abs(centered.x + centered.y * 0.55));
	color += border_color.rgb * highlight * 0.10;
	color = mix(color, border_color.rgb, edge * border_color.a * 0.34);
	COLOR = vec4(color, alpha);
}
