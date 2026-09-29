shader_type canvas_item;
uniform vec4 current_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 next_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float frame_mix = 0.0;
uniform vec4 target_color : source_color = vec4(1.0);
uniform float effect_intensity = 1.0;
uniform bool colorize = false;
varying vec4 vertex_color;

void vertex() { vertex_color = COLOR; }

void fragment() {
	vec2 local_uv = (UV - current_rect.xy) / current_rect.zw;
	vec2 half_texel = TEXTURE_PIXEL_SIZE * 0.5;
	vec2 uv_a = clamp(UV, current_rect.xy + half_texel, current_rect.xy + current_rect.zw - half_texel);
	vec2 uv_b = clamp(next_rect.xy + local_uv * next_rect.zw, next_rect.xy + half_texel, next_rect.xy + next_rect.zw - half_texel);
	vec4 a = texture(TEXTURE, uv_a);
	vec4 b = texture(TEXTURE, uv_b);
	// Interpolate premultiplied RGB to avoid dark fringes around translucent mist.
	float alpha = mix(a.a, b.a, frame_mix);
	vec3 rgb = mix(a.rgb * a.a, b.rgb * b.a, frame_mix) / max(alpha, 0.00001);
	if (colorize) { rgb = vec3(max(rgb.r, max(rgb.g, rgb.b))); }
	COLOR = vec4(rgb * target_color.rgb, alpha * effect_intensity) * vertex_color;
}
