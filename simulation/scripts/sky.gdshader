shader_type sky;

// --- 1. CORE NOISE FUNCTIONS ---
vec2 random(vec2 uv) {
    uv = vec2(dot(uv, vec2(127.1, 311.7)), dot(uv, vec2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(uv) * 43758.5453123);
}

float noise(vec2 uv) {
    vec2 i = floor(uv); 
    vec2 f = fract(uv);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    
    float a = dot(random(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0));
    float b = dot(random(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
    float c = dot(random(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
    float d = dot(random(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
    
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) + 0.5;
}

const mat2 m = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));

float fbm(vec2 uv, int octaves) {
    float f = 0.0; float amp = 0.5; 
    for (int i = 0; i < octaves; i++) { 
        f += amp * noise(uv); uv = m * uv * 2.02; amp *= 0.5;
    }
    return f;
}

// --- 2. RAW CLOUD SHAPE GENERATOR ---
// Removed the harsh 2D smoothstep thresholding. We now return the raw 
// noise so we can dynamically carve it in 3D during the raymarch.
float get_cloud_noise(vec2 p) {
    p += TIME * 0.015; 
    
    vec2 warp = vec2(fbm(p * 0.5, 4), fbm(p * 0.5 + vec2(5.2, 1.3), 4));
    p += warp * 0.4; 
    
    float n = fbm(p, 9);
    float macro = fbm(p * 0.15, 4);
    
    return n * smoothstep(0.1, 0.7, macro); 
}

// --- 3. MAIN SKY SHADER ---
void sky() {
    float t = EYEDIR.y;
    vec3 sun_dir = normalize(vec3(0.8, 0.6, 0.3)); 
    
    // --- LAYER 1: ATMOSPHERE BUBBLE & RIM LIGHT ---
    float h_horizon = max(t + 0.1, 0.0); 
    
    float bubble_fade = 1.0 - smoothstep(0.0, 0.12, h_horizon);
    
    vec3 deep_blue = vec3(0.02, 0.12, 0.5);
    vec3 atmos = mix(vec3(0.0), deep_blue, pow(bubble_fade, 3.0));
    
    vec3 rim_color = vec3(0.3, 0.65, 1.0); 
    atmos = mix(atmos, rim_color, pow(bubble_fade, 60.0));
    
    float sun_alignment = max(dot(EYEDIR, sun_dir), 0.0);
    atmos *= (1.0 + pow(sun_alignment, 3.0) * 0.8);
    
    vec3 col = atmos;

    // --- LAYER 2: SURFACE & VOLUMETRIC CLOUDS ---
    // Start evaluating slightly earlier to allow 3D height to break the horizon
    if (t < -0.06) { 
        float cam_alt   = 80000.0;  
        float water_alt = 0.0;      
        
        // Define physical top and bottom of the cloud layer
        float cloud_top = 7000.0;   
        float cloud_bot = 3500.0;   
        
        float t_water = (water_alt - cam_alt) / t;
        float t_top   = (cloud_top - cam_alt) / t;
        float t_bot   = (cloud_bot - cam_alt) / t;
        
        float scale = 0.00005; 
        vec2 pos_water = EYEDIR.xz * t_water * scale;
        
        // 1. Water Shadow (Sampled once at the middle altitude of the clouds)
        float shadow_ray_dist = (5250.0 - water_alt) / sun_dir.y;
        vec2 shadow_hit = pos_water + (sun_dir.xz * shadow_ray_dist) * scale;
        float shadow_n = get_cloud_noise(shadow_hit);
        float shadow_mask = smoothstep(0.4, 0.6, shadow_n); 
        vec3 water_base = vec3(0.01, 0.05, 0.15);
        vec3 water_shadow = water_base * 0.2;
        vec3 current_water = mix(water_base, water_shadow, shadow_mask * 0.9);
        
        // 2. Volumetric Raymarching for Clouds
        int steps = 12;
        float step_dist = (t_bot - t_top) / float(steps);
        
        // Jitter the starting ray position to completely hide planar slicing artifacts
        float jitter = fract(sin(dot(EYEDIR.xz, vec2(12.9898, 78.233))) * 43758.5453);
        float cur_t = t_top + step_dist * jitter;
        
        float accum_alpha = 0.0;
        vec3 accum_color = vec3(0.0);
        
        vec3 cloud_lit = vec3(1.0, 0.98, 0.95);
        vec3 cloud_dark = vec3(0.35, 0.4, 0.5);
        
        for(int i = 0; i < 12; i++) {
            if (accum_alpha > 0.99) break; // Early exit if cloud is solid
            
            vec3 pos = EYEDIR * cur_t; 
            float actual_y = cam_alt + pos.y;
            vec2 uv = pos.xz * scale;
            
            // Normalized altitude inside the cloud (0.0 = bottom, 1.0 = top)
            float h = clamp((actual_y - cloud_bot) / (cloud_top - cloud_bot), 0.0, 1.0);
            
            float raw_n = get_cloud_noise(uv);
            
            // 3D Shaping: Aggressively carve the noise at the top to make puffy domes, 
            // and gently flatten the bottom.
            float density_shape = raw_n - (h * h * 0.5) - (pow(1.0 - h, 2.0) * 0.2);
            
            // Tighten the edges to keep precision
            float local_density = smoothstep(0.35, 0.45, density_shape);
            
            if (local_density > 0.0) {
                // Lighting: Tops are bright, bellies are dark. We also shadow the 
                // deeper parts of the cloud based on how much alpha is above it.
                vec3 step_color = mix(cloud_dark, cloud_lit, h * 0.9 + 0.1);
                step_color = mix(step_color, cloud_dark, accum_alpha * 0.7); 
                
                float step_alpha = local_density * 0.4;
                
                // Front-to-back pre-multiplied blending
                accum_color += step_color * step_alpha * (1.0 - accum_alpha);
                accum_alpha += step_alpha * (1.0 - accum_alpha);
            }
            cur_t += step_dist;
        }
        
        // Un-premultiply the final color for accurate atmospheric haze tinting
        if (accum_alpha > 0.001) {
            accum_color /= accum_alpha;
        }
        
        // --- 3. ALPHA BLENDING & COMPOSITING ---
        float water_alpha = smoothstep(-0.098, -0.102, t); 
        float cloud_alpha = smoothstep(-0.06, -0.09, t) * accum_alpha; 
        
        float haze = smoothstep(-0.17, -0.08, t); 
        
        vec3 hazed_water = mix(current_water, atmos, haze);
        vec3 hazed_cloud = mix(accum_color, atmos, haze * 0.85); 
        
        col = mix(col, hazed_water, water_alpha);
        col = mix(col, hazed_cloud, cloud_alpha); 
    }

    COLOR = col;
}