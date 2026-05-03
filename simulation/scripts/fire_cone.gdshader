shader_type spatial;
render_mode blend_add, cull_disabled, depth_draw_never, unshaded;

uniform float model_height = 6.0;
uniform float dissolve_start : hint_range(0.0, 1.0) = 0.001;
uniform float dissolve_length : hint_range(0.0, 1.0) = 0.75;
uniform float gradient_bias : hint_range(0.1, 5.0) = 1.0;

uniform float noise_speed = 1.0; // Speed of noise movement
uniform float noise_strength = 0.1; // Strength of the noise effect
uniform float stretch_factor = 0.6; // Factor to stretch the noise
uniform sampler2D noise_texture; // Noise texture

uniform vec3 _color = vec3(1);
uniform float power_factor = 1;


varying float vert_height;
varying vec2 v_uv;

void vertex() {
    vert_height = (VERTEX.y + (model_height / 2.0)) / model_height;
    v_uv = UV;
}

vec3 neon(float value, vec3 color) {
	float ramp = clamp(value, 0.0, 1.0);
	vec3 output_color = vec3(0.0);
	ramp = ramp * ramp;
	output_color += pow(color, vec3(4.0)) * ramp;
	ramp = ramp * ramp;
	output_color += color * ramp;
	ramp = ramp * ramp;
	output_color += vec3(1.0) * ramp;
	return output_color;
}

void fragment(){
	float time = TIME * noise_speed;
	vec2 moving_uv = v_uv + vec2(0,1)*time;
	vec2 stretched_uv = vec2(moving_uv.x, moving_uv.y * stretch_factor);
	float noise_value = texture(noise_texture, stretched_uv).r * noise_strength;
	float gradient_height = vert_height - dissolve_start;
	gradient_height *= 1.0 / dissolve_length;
	gradient_height = clamp(pow(gradient_height, gradient_bias) + noise_value, 0.0, 1.0);
  
	ALPHA = mix(1.0, 0.0, gradient_height);
	ALBEDO = vec3(1.0 - gradient_height);
	ALBEDO = neon(pow(ALPHA, power_factor), _color);
}