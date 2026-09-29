shader_type canvas_item;
render_mode unshaded;

// The screen texture is the Godot viewport behind this surface. Native
// companion windows cannot sample the desktop through this shader.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float blur_amount : hint_range(0.0, 5.0) = 2.5;
uniform vec4 tint_color : source_color = vec4(0.75, 0.88, 1.0, 0.18);
uniform vec4 border_color : source_color = vec4(0.65, 0.84, 1.0, 0.55);
uniform float border_width : hint_range(0.0, 0.08) = 0.018;
uniform float corner_radius : hint_range(0.0, 0.5) = 0.08;

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

	vec4 behind = textureLod(screen_texture, SCREEN_UV, blur_amount);
	vec3 color = mix(behind.rgb, tint_color.rgb, tint_color.a);
	float edge = 1.0 - smoothstep(0.0, border_width, abs(sdf));
	color = mix(color, border_color.rgb, edge * border_color.a);
	COLOR = vec4(color, alpha);
}
