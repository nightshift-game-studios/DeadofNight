shader_type spatial;
// Zombie health bar: one camera-facing quad per zombie. Frame, notches, cut corners,
// fill and the "recent damage" ghost are all drawn here, so a bar is a single draw call.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix, fog_disabled;

uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform float ghost : hint_range(0.0, 1.0) = 1.0;
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
uniform float aspect = 7.0; // quad width / height
uniform vec4 fill_color : source_color = vec4(0.78, 0.07, 0.05, 1.0);
uniform vec4 ghost_color : source_color = vec4(0.89, 0.85, 0.74, 0.85);
uniform vec4 back_color : source_color = vec4(0.045, 0.045, 0.04, 0.82);
uniform vec4 frame_color : source_color = vec4(0.66, 0.63, 0.55, 0.9);
// Distance scaling: the bar grows in world size with distance (between min/max) so it stays
// readable far away without covering the zombie up close.
uniform float ref_distance = 7.0;
uniform float min_scale = 0.35;
uniform float max_scale = 2.4;

void vertex() {
	vec4 origin = MODEL_MATRIX[3];
	float dist = length((VIEW_MATRIX * origin).xyz);
	float s = clamp(dist / ref_distance, min_scale, max_scale);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], origin);
	VERTEX.xy *= s;
}

void fragment() {
	vec2 uv = UV;
	float h = 1.0 / aspect; // one "unit" of bar height in x-UV
	// chamfer top-left and bottom-right corners
	float cut = 0.38;
	if (uv.x / h + uv.y < cut || (1.0 - uv.x) / h + (1.0 - uv.y) < cut) {
		discard;
	}
	float bx = 0.16 * h; // frame thickness (x)
	float by = 0.16;     // frame thickness (y)
	vec4 c = frame_color;
	if (uv.x > bx && uv.x < 1.0 - bx && uv.y > by && uv.y < 1.0 - by) {
		float t = (uv.x - bx) / (1.0 - 2.0 * bx);
		c = back_color;
		if (t < ghost) { c = ghost_color; }
		if (t < fill) { c = fill_color; }
		// segment notches every 10%
		float seg = fract(t * 10.0);
		if (seg < 0.06 && t > 0.02) { c.rgb *= 0.35; }
		// worn top highlight
		if (uv.y < by + 0.12) { c.rgb *= 1.15; }
	}
	ALBEDO = c.rgb;
	ALPHA = c.a * alpha;
}
