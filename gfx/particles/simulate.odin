package particles

particle_src_types :: `

#version 450

#define PI 3.1415926535897932384626433832795
#define E 2.7182818284590452353602874713527

struct Particle {
    vec3 pos;
    vec4 color;
    vec3 size;
    vec3 rotation;
};

// Needs to be aligned to 16!
#define PROPERTY_BASE int kind;\
int distribution;\
int interp_kind;\
float seed;\
int scalar_or_component_rand;\
bool soft_lock_rand_range;\
float pad1_;\
float pad2_;

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !! All these structs need to be explicitly aligned to 16 bytes !!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

// 32 bytes
struct Property_F32 {
    PROPERTY_BASE // 16 bytes

    float value1;
    float value2;

    float pad1;
    float pad2;
};
// 48 bytes
struct Property_Vec2 {
    PROPERTY_BASE // 16 bytes

    vec2 value1;
    vec2 value2;
};
// 48 bytes
struct Property_Vec3 {
    PROPERTY_BASE // 16 bytes

    vec3 value1;  // 16 bytes
    vec3 value2;  // 16 bytes
};
// 48 bytes
struct Property_Vec4 {
    PROPERTY_BASE // 16 bytes

    vec4 value1; // 16 bytes
    vec4 value2; // 16 bytes
};
struct Spawn_Area {
    /*
    For some reason in this particular struct the vec3's arent padded 
    to 16 bytes !?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!?!?!?!??!?!?!!?!?!?!?!?!??!?!?!!?!??!?!!?!? 
    */
    vec3 pos;
    float pad0;
    vec3 rotation;
    float pad1;
    vec3 size;
    float pad2;

    int kind;
    int spawn_distribution;
    int rand_spawn_distribution;
    int scalar_or_component_rand;
};
struct Emitter_Config {
    float emission_rate; // 0-4
    float pad0; // 4-8
    float seed; // 8-12
    int particle_kind; // 12-16

    ivec2 rand_map_size; // 16-24
    bool should_only_2D; // 24-28
    bool should_loop; // 28-32

    Spawn_Area spawn_area;
    
    Property_Vec3 size;
    Property_Vec4 color;
    Property_Vec3 velocity;
    Property_Vec3 acceleration;
    Property_Vec2 angular_velocity; // yaw, pitch
    Property_Vec2 angular_acceleration; // yaw, pitch
    Property_Vec3 rotation;
    Property_F32 lifetime;


    mat4 model;
};

` particle_compute_src :: `

layout(local_size_x = MAX_COMPUTE_SIZE) in;

// Vulkan GLSL facepalm
layout(std140, binding = 0) uniform Emitter_Config_ { Emitter_Config emitter; };

layout (std140, binding = 1) buffer Emitter_Simulation_Data {
    Particle particles[NUM_PARTICLES];
};

layout (binding = 2) uniform sampler2D u_random_texture;

layout(push_constant) uniform Simulation_State {
    float now;
    int first_index;
};

float rand(float seed) {
    int rand_map_texel_count = emitter.rand_map_size.x * emitter.rand_map_size.y;
    int rand_map_texel_index = int(mod(seed, float(rand_map_texel_count)));

    int texel_x = rand_map_texel_index % emitter.rand_map_size.x;
    int texel_y = rand_map_texel_index / emitter.rand_map_size.x;

    float uv_x = (float(texel_x) + 0.5) / float(emitter.rand_map_size.x);
    float uv_y = (float(texel_y) + 0.5) / float(emitter.rand_map_size.y);

    return texture(u_random_texture, vec2(uv_x, uv_y)).r;
}
float rand_range(float seed, float min, float max) {
    return min + (max-min) * rand(seed);
}


float rand_normal(float seed) {

    float u1 = rand(seed);
    float u2 = rand(seed + 1.0);

    if (u1 <= 0) u1 = 0.0001f;
    if (u2 <= 0) u2 = 0.0001f;

    float g = sqrt(-2 * log(u1)) * cos(2 * PI * u2);

    float deviation = 3.0;

    return (g + deviation) / (deviation*2);
}
float rand_range_normal(float seed, float min, float max) {
    return min + (max-min) * rand_normal(seed);
}

float rand_extremes(float seed) {
    float u1 = rand(seed);
    u1 = u1 * u1;
    u1 -= 1;
    if (rand(seed + 1.0) < 0.5) u1 = -u1;
    u1 += 1;
    u1 *= 0.5;

    return u1;
}
float rand_range_extremes(float seed, float min, float max) {
    return min + (max-min) * rand_extremes(seed);
}

float rand_neg_logx(float seed) {
    float u = rand(seed);

    return -log(u);
}
float rand_range_neg_logx(float seed, float min, float max) {
    return min + (max-min) * rand_neg_logx(seed);
}
float oscillate(float n, float t) {
    return (sin(n*2*PI*(t-(1.0/(n*4))))+1.0) / 2.0;
}
float sample_rand(float value1, float value2, int distribution, float seed, bool soft_lock_rand_range) {
    float v;
    float u = rand(seed);
    
    switch (distribution) {
        case UNIFORM:
            v = u;
            break;
        case NORMAL:
            v = rand_normal(seed);
            break;
        case EXTREMES:
            v = rand_extremes(seed);
            break;
        case NEG_LOGX:
            v = rand_neg_logx(seed);
            break;
        case X_SQUARED:
            v = u * u;
            break;
        case X_CUBED:
            v = u * u * u;
            break;
        case X_FOURTH:
            v = u * u * u * u;
            break;
        case X_FIFTH:
            v = u * u * u * u * u;
            break;
        case INV_X_SQUARED:
            v = 1 - u * u;
            break;
        case INV_X_CUBED:
            v = 1 - u * u * u;
            break;
        case INV_X_FOURTH:
            v = 1 - u * u * u * u;
            break;
        case INV_X_FIFTH:
            v = 1 - u * u * u * u * u;
            break;
        case TWO_DICE: {
            float u1 = rand(seed + 1.0);
            v = (u + u1) * (1.0/2.0);
            break;
        }
        case THREE_DICE: {
            float u1 = rand(seed + 1.0);
            float u2 = rand(seed + 2.0);
            v = (u + u1 + u2) * (1.0/3.0);
            break;
        }
        case FOUR_DICE: {
            float u1 = rand(seed + 1.0);
            float u2 = rand(seed + 2.0);
            float u3 = rand(seed + 3.0);
            v = (u + u1 + u2 + u3) * (1.0/4.0);
            break;
        }
        case TWO_DICE_SQUARED: {
            float u1 = rand(seed + 1.0);
            v = (u + u1) * (1.0/2.0);
            v = v * v;
            break;
        }
        case THREE_DICE_SQUARED: {
            float u1 = rand(seed + 1.0);
            float u2 = rand(seed + 2.0);
            v = (u + u1 + u2) * (1.0/3.0);
            v = v * v;
            break;
        }
        case FOUR_DICE_SQUARED: {
            float u1 = rand(seed + 1.0);
            float u2 = rand(seed + 2.0);
            float u3 = rand(seed + 3.0);
            v = (u + u1 + u2 + u3) * (1.0/4.0);
            v = v * v;
            break;
        }
        case OSCILLATE1: {
            v = oscillate(1.0, u);
            break;
        }
        case OSCILLATE2: {
            v = oscillate(2.0, u);
            break;
        }
        case OSCILLATE3: {
            v = oscillate(3.0, u);
            break;
        }
        case OSCILLATE4: {
            v = oscillate(4.0, u);
            break;
        }
    }
    v = mix(value1, value2, v);
    
    if (!soft_lock_rand_range) {
        v = clamp(v, value1, value2);
    }

    return v;
}
float read_property_f32(Property_F32 prop, float seed, float life_factor) {
    float unique_seed = seed + prop.seed;
    if (prop.kind == CONSTANT) {
        return prop.value1;
    } else if (prop.kind == RANDOM) {
        return sample_rand(prop.value1, prop.value2, prop.distribution, unique_seed, prop.soft_lock_rand_range);
    } else if (prop.kind == INTERPOLATE) {
        if (prop.interp_kind == LINEAR) {
            return mix(prop.value1, prop.value2, life_factor);
        } else if (prop.interp_kind == SMOOTH) {
            return smoothstep(0.0, 1.0, life_factor) * (prop.value2 - prop.value1) + prop.value1;
        }
    }
    return 0.0;
}
vec2 read_property_vec2(Property_Vec2 prop, float seed, float life_factor) {
    float unique_seed = seed + prop.seed;
    if (prop.kind == CONSTANT) {
        return prop.value1;
    } else if (prop.kind == RANDOM) {
        float seed_offset_factor = 1.0;
        if (prop.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;
        return vec2(
            sample_rand(prop.value1.x, prop.value2.x, prop.distribution, unique_seed + 0 * seed_offset_factor, prop.soft_lock_rand_range),
            sample_rand(prop.value1.y, prop.value2.y, prop.distribution, unique_seed + 1 * seed_offset_factor, prop.soft_lock_rand_range)
        );
    } else if (prop.kind == INTERPOLATE) {
        if (prop.interp_kind == LINEAR) {
            return mix(prop.value1, prop.value2, life_factor);
        } else if (prop.interp_kind == SMOOTH) {
            return smoothstep(0.0, 1.0, life_factor) * (prop.value2 - prop.value1) + prop.value1;
        }
    }
    return vec2(0);
}
vec3 read_property_vec3(Property_Vec3 prop, float seed, float life_factor) {
    float unique_seed = seed + prop.seed;
    if (prop.kind == CONSTANT) {
        return prop.value1;
    } else if (prop.kind == RANDOM) {
        float seed_offset_factor = 1.0;
        if (prop.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;
        return vec3(
            sample_rand(prop.value1.x, prop.value2.x, prop.distribution, unique_seed + 0 * seed_offset_factor, prop.soft_lock_rand_range),
            sample_rand(prop.value1.y, prop.value2.y, prop.distribution, unique_seed + 1 * seed_offset_factor, prop.soft_lock_rand_range),
            sample_rand(prop.value1.z, prop.value2.z, prop.distribution, unique_seed + 2 * seed_offset_factor, prop.soft_lock_rand_range)
        );
        
    } else if (prop.kind == INTERPOLATE) {
        if (prop.interp_kind == LINEAR) {
            return mix(prop.value1, prop.value2, life_factor);
        } else if (prop.interp_kind == SMOOTH) {
            return smoothstep(0.0, 1.0, life_factor) * (prop.value2 - prop.value1) + prop.value1;
        }
    }
    return vec3(0);
}
vec4 read_property_vec4(Property_Vec4 prop, float seed, float life_factor) {
    float unique_seed = seed + prop.seed;
    if (prop.kind == CONSTANT) {
        return prop.value1;
    } else if (prop.kind == RANDOM) {
        float seed_offset_factor = 1.0;
        if (prop.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;
        return vec4(
            sample_rand(prop.value1.x, prop.value2.x, prop.distribution, unique_seed + 0 * seed_offset_factor, prop.soft_lock_rand_range),
            sample_rand(prop.value1.y, prop.value2.y, prop.distribution, unique_seed + 1 * seed_offset_factor, prop.soft_lock_rand_range),
            sample_rand(prop.value1.z, prop.value2.z, prop.distribution, unique_seed + 2 * seed_offset_factor, prop.soft_lock_rand_range),
            sample_rand(prop.value1.w, prop.value2.w, prop.distribution, unique_seed + 3 * seed_offset_factor, prop.soft_lock_rand_range)
        );
        
    } else if (prop.kind == INTERPOLATE) {
        if (prop.interp_kind == LINEAR) {
            return mix(prop.value1, prop.value2, life_factor);
        } else if (prop.interp_kind == SMOOTH) {
            return smoothstep(0.0, 1.0, life_factor) * (prop.value2 - prop.value1) + prop.value1;
        }
    }
    return vec4(0);
}

mat3 make_rotation(vec3 euler) {
    float cz = cos(euler.z);
    float sz = sin(euler.z);
    float cy = cos(euler.y);
    float sy = sin(euler.y);
    float cx = cos(-euler.x);
    float sx = sin(-euler.x);

    return mat3(
        cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx,
        sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx,
        -sy,    cy * sx,              cy * cx
    );
}
vec3 rotate_point(vec3 point, vec3 center, mat3 rotation) {
    vec3 translated = point - center;
    vec3 rotated = rotation * translated;
    return rotated + center;
}

void main() {

    // Instead of hard-limit to NUM_PARTICLES we can wrap around but
    // this means client needs to have precise control over the dispatched
    // compute jobs. This lets us dispatch compute on one range of particles
    // that start near the end but wraps around to the start.
    uint idx = (gl_GlobalInvocationID.x + first_index) % NUM_PARTICLES;

    Particle p = particles[idx];

    // #Speed #Redundant
    // Used highp floats here for extra precision for old random
    // function. Could potentially used regular floats without
    // the loss of precision having any effect.
    float emission_interval = 1.0 / emitter.emission_rate;

    float time_when_last_particle_is_emitted = NUM_PARTICLES * emission_interval;


    float emission_time = float(idx) * emission_interval;

    float particle_seed = emitter.seed + float(idx);

    float life_time = read_property_f32(emitter.lifetime, particle_seed, 1.0);

    // Will loop
    float age;
    if (emitter.should_loop) {
        age = mod(float(now - emission_time), max(time_when_last_particle_is_emitted, life_time));
    } else {
        age = float(now - emission_time);
    }
    float life_factor = age / life_time;

    if (life_factor > 1.0) {
        particles[idx].color = vec4(0,0,0,0);
        return;
    }
    if (life_factor < 0.0) {
        particles[idx].color = vec4(0,0,0,0);
        return;
    }

    vec3 velocity = read_property_vec3(emitter.velocity, particle_seed, life_factor);
    vec3 acceleration = read_property_vec3(emitter.acceleration, particle_seed, life_factor);
    velocity += acceleration * age;


    vec2 angular_velocity = read_property_vec2(emitter.angular_velocity, particle_seed, life_factor);
    vec2 angular_acceleration = read_property_vec2(emitter.angular_acceleration, particle_seed, life_factor);
    angular_velocity += angular_acceleration * age;

    float total_yaw = angular_velocity.x * age;
    float total_pitch = angular_velocity.y * age;

    mat3 yaw_rotation = mat3(cos(total_yaw), 0, sin(total_yaw),
                            0, 1, 0,
                            -sin(total_yaw), 0, cos(total_yaw));
    mat3 pitch_rotation = mat3(1, 0, 0,
                            0, cos(total_pitch), -sin(total_pitch),
                            0, sin(total_pitch), cos(total_pitch));

    mat3 total_rotation = pitch_rotation * yaw_rotation;
    velocity = total_rotation * velocity;

    vec3 start_pos = vec3(0);

    switch (emitter.spawn_area.kind) {
        case AREA_RECTANGLE: {
            // #Speed
            // This is a lot of computation for each particle every
            // simulation step even though its going to be the same
            // each step.
            
            vec3 center = emitter.spawn_area.pos;
            // Ignore z because its 2D
            // Assume a rectangle facing the z-axis.
            // Right-handed X and up is Y
            vec2 size = emitter.spawn_area.size.xy;

            float L = center.x + -size.x / 2.0;
            float R = center.x + size.x / 2.0;
            float B = center.y + -size.y / 2.0;
            float T = center.y + size.y / 2.0;
            float z = center.z;

            vec3 BL = vec3(L, B, z);
            vec3 TL = vec3(L, T, z);
            vec3 TR = vec3(R, T, z);
            vec3 BR = vec3(R, B, z);

            vec3 euler = emitter.spawn_area.rotation;

            // But use all euler angles because we may want to orient
            // the rectangle in 3D space
            mat3 rotation = make_rotation(euler);

            switch (emitter.spawn_area.spawn_distribution) {
                case SPAWN_DIST_RANDOM: {
                    float seed_offset_factor = 1.0;
                    if (emitter.spawn_area.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;

                    vec3 point = vec3(
                        sample_rand(BL.x, BR.x, emitter.spawn_area.rand_spawn_distribution, particle_seed + 0 * seed_offset_factor, false),
                        sample_rand(BL.y, TL.y, emitter.spawn_area.rand_spawn_distribution, particle_seed + 1 * seed_offset_factor, false),
                        sample_rand(BL.z, TR.z, emitter.spawn_area.rand_spawn_distribution, particle_seed + 2 * seed_offset_factor, false)
                    );
                    start_pos += rotate_point(point, center, rotation);

                    break;
                }
                case SPAWN_DIST_OUTWARDS: {
                    break;
                }
                case SPAWN_DIST_INWARDS: {
                    break;
                }
            }

            break;
        }
        case AREA_CIRCLE: {
            vec3 center = emitter.spawn_area.pos;
            float radius = emitter.spawn_area.size.x;
            vec3 euler = emitter.spawn_area.rotation;
            mat3 rotation = make_rotation(euler);

            switch (emitter.spawn_area.spawn_distribution) {
                case SPAWN_DIST_RANDOM: {
                    float seed_offset_factor = 1.0;
                    if (emitter.spawn_area.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;

                    float angle = sample_rand(0, 2*PI, emitter.spawn_area.rand_spawn_distribution, particle_seed, false);
                    float dist = sqrt(sample_rand(0, 1, emitter.spawn_area.rand_spawn_distribution, particle_seed + 1 * seed_offset_factor, false)) * radius;
                    float x = dist * cos(angle);
                    float y = dist * sin(angle);

                    start_pos += rotate_point(vec3(x, y, 0), center, rotation);

                    break;
                }
                case SPAWN_DIST_OUTWARDS: {
                    break;
                }
                case SPAWN_DIST_INWARDS: {
                    break;
                }
            }

            break;
        }
        case AREA_SPHERE: {
            vec3 center = emitter.spawn_area.pos;
            float radius = emitter.spawn_area.size.x;

            switch (emitter.spawn_area.spawn_distribution) {
                case SPAWN_DIST_RANDOM: {
                    float seed_offset_factor = 1.0;
                    if (emitter.spawn_area.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;

                    float theta = sample_rand(0, 2 * PI, emitter.spawn_area.rand_spawn_distribution, particle_seed + 0 * seed_offset_factor, false);
                    float phi = acos(2 * sample_rand(0, 1, emitter.spawn_area.rand_spawn_distribution, particle_seed + 1 * seed_offset_factor, false) - 1);
                    
                    vec3 dir = vec3(
                        sin(phi) * cos(theta),
                        sin(phi) * sin(theta),
                        cos(phi)
                    );

                    float u = sample_rand(0, 1, emitter.spawn_area.rand_spawn_distribution, particle_seed + 2 * seed_offset_factor, false);
                    float dist = radius * sqrt(u);

                    start_pos += dir * dist;

                    break;
                }
                case SPAWN_DIST_OUTWARDS: {
                    break;
                }
                case SPAWN_DIST_INWARDS: {
                    break;
                }
            }

            break;
        }
        case AREA_CUBE: {
            vec3 center = emitter.spawn_area.pos;
            vec3 size = emitter.spawn_area.size;
            vec3 euler = emitter.spawn_area.rotation;
            mat3 rotation = make_rotation(euler);

            switch (emitter.spawn_area.spawn_distribution) {
                case SPAWN_DIST_RANDOM: {
                    float seed_offset_factor = 1.0;
                    if (emitter.spawn_area.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;

                    vec3 point = vec3(
                        sample_rand(-size.x / 2.0, size.x / 2.0, emitter.spawn_area.rand_spawn_distribution, particle_seed + 0 * seed_offset_factor, false),
                        sample_rand(-size.y / 2.0, size.y / 2.0, emitter.spawn_area.rand_spawn_distribution, particle_seed + 1 * seed_offset_factor, false),
                        sample_rand(-size.z / 2.0, size.z / 2.0, emitter.spawn_area.rand_spawn_distribution, particle_seed + 2 * seed_offset_factor, false)
                    );

                    start_pos += rotate_point(point, center, rotation);

                    break;
                }
                case SPAWN_DIST_OUTWARDS: {
                    break;
                }
                case SPAWN_DIST_INWARDS: {
                    break;
                }
            }

            break;
        }
        case AREA_ELLIPSOID: {
            vec3 center = emitter.spawn_area.pos;
            vec3 size = emitter.spawn_area.size;
            vec3 euler = emitter.spawn_area.rotation;
            mat3 rotation = make_rotation(euler);

            float seed_offset_factor = 1.0;
            if (emitter.spawn_area.scalar_or_component_rand == SCALAR) seed_offset_factor = 0.0;

            float theta = sample_rand(0, 2 * PI, emitter.spawn_area.rand_spawn_distribution, particle_seed + 0 * seed_offset_factor, false);
            float phi = acos(2 * sample_rand(0, 1, emitter.spawn_area.rand_spawn_distribution, particle_seed + 1 * seed_offset_factor, false) - 1);
            float u = sample_rand(0, 1, emitter.spawn_area.rand_spawn_distribution, particle_seed + 2 * seed_offset_factor, false);
            float radius = sqrt(u);

            vec3 dir = vec3(
                radius * sin(phi) * cos(theta),
                radius * sin(phi) * sin(theta),
                radius * cos(phi)
            );

            vec3 point = vec3(
                dir.x * size.x / 2.0, // x * a
                dir.y * size.y / 2.0, // y * b
                dir.z * size.z / 2.0  // z * c
            );

            start_pos += rotate_point(point, center, rotation);
            break;
        }
        case AREA_POINT: {
            start_pos += emitter.spawn_area.pos;

            break;
        }
        default: {
            start_pos = vec3(-999);
            break;
        }
    }

    p.pos = start_pos + velocity * age;

    p.size = read_property_vec3(emitter.size, particle_seed, life_factor);

    p.color = read_property_vec4(emitter.color, particle_seed, life_factor);

    p.rotation = read_property_vec3(emitter.rotation, particle_seed, life_factor);

    particles[idx] = p;
}
`;

particle_vert_src :: `

layout (push_constant) uniform Transform_Data {
    mat4 u_proj;
    mat4 u_view; // This guy is cheeky
};

layout (std140, binding = 0) buffer Emitter_Simulation_Data {
    Particle particles[NUM_PARTICLES];
};
// Vulkan GLSL facepalm
layout(std140, binding = 1) uniform Emitter_Config_ { Emitter_Config emitter; };

layout (location = 0) out vec4 v_color;
layout (location = 1) out vec3 v_local_pos;
layout (location = 2) flat out int v_particle_kind;

mat4 translate(vec3 delta)
{
    mat4 m;
    m[0][0] = 1;
    m[1][1] = 1;
    m[2][2] = 1;
    m[3] = vec4(delta, 1.0);
    return m;
}

void main() {

    // #Hack Cheeky.
    // We want to keep push constant under 128 bytes so we use one of
    // the 0's in the view matrix to store the index offset.
    mat4 view = u_view;
    int index_offset = int(round(view[2][3]));
    view[2][3] = 0.0;

    int index = (gl_InstanceIndex + index_offset) % NUM_PARTICLES;
    Particle p = particles[index];

    if (p.color.a <= 0.0000001) {
        gl_Position = vec4(0); // Ignore this particle
        return;
    }

    vec3 local_pos;

    // #Incomplete
    // Only for 2D Quads
    int local_index = gl_VertexIndex % 6;
    if (local_index == 0) {
        local_pos = vec3(-1, -1, 0);  // BL
    } else if (local_index == 1) {
        local_pos = vec3(-1, 1, 0);  // TL
    } else if (local_index == 2) {
        local_pos = vec3(1, 1, 0);  // TR
    } else if (local_index == 3) {
        local_pos = vec3(-1, -1, 0);  // BL
    } else if (local_index == 4) {
        local_pos = vec3(1, 1, 0);  // TR
    } else if (local_index == 5) {
        local_pos = vec3(1, -1, 0);  // BR
    }

    v_color = p.color;
    v_local_pos = local_pos;
    v_particle_kind = emitter.particle_kind;

    if (v_particle_kind == RECTANGLE || v_particle_kind == CIRCLE || v_particle_kind == TRIANGLE || v_particle_kind == TEXTURE) {

        vec3 cam_right = normalize(vec3(view[0][0], view[1][0], view[2][0]));
        vec3 cam_up = normalize(vec3(view[0][1], view[1][1], view[2][1]));
        vec3 cam_forw = cross(cam_right, cam_up);
        mat3 billboard_rotation = mat3(cam_right, -cam_up, cam_forw);
        
        // #Incomplete
        // For 3D particles we use all euler angles
        float rotation = p.rotation.z;
        mat3 rotation_mat = mat3(cos(rotation),	-sin(rotation), 0,
        sin(rotation),	cos(rotation),  0,
        0, 0, 1);
        
        vec3 local_pos = rotation_mat * (local_pos * p.size);

        vec3 vert_pos = billboard_rotation * local_pos + p.pos;

        if (emitter.should_only_2D) {
            vert_pos.z = 0;
        }

        // Now transform to clip space
        gl_Position = u_proj 
                    * view 
                    * emitter.model 
                    * vec4(vert_pos, 1.0);
    } else {
        // #Incomplete
        v_color = vec4(1, 0, 0, 1);
        return;
    }

}`



particle_frag_src :: `
layout (location = 0) out vec4 o_result;

layout (location = 0) in vec4 v_color;
layout (location = 1) in vec3 v_local_pos;
layout (location = 2) flat in int v_particle_kind;

layout (binding = 2) uniform sampler2D u_texture;

void main() {


    if (v_color.a <= 0.0000001) {
        discard;
    }

    if (v_particle_kind == RECTANGLE) {
        o_result = v_color;
    } else if (v_particle_kind == CIRCLE) {
        if (length(v_local_pos) > 1.0) {
            discard;
        }
        o_result = v_color;
    } else if (v_particle_kind == TRIANGLE) {
        vec2 BL = vec2(-1,  1);  // Top left
        vec2 BR = vec2(1,  1);   // Top right
        vec2 T = vec2(0, -1);    // Bottom

        float side1 = (BR.x - BL.x) * (v_local_pos.y - BL.y) - (BR.y - BL.y) * (v_local_pos.x - BL.x);
        float side2 = (T.x - BR.x)  * (v_local_pos.y - BR.y) - (T.y - BR.y)  * (v_local_pos.x - BR.x);
        float side3 = (BL.x - T.x)  * (v_local_pos.y - T.y)  - (BL.y - T.y)  * (v_local_pos.x - T.x);

        if (!(side1 <= 0.0 && side2 <= 0.0 && side3 <= 0.0)) {
            discard;
        }
        o_result = v_color;
    } else if (v_particle_kind == TEXTURE) {
        vec2 uv = v_local_pos.xy * 0.5 + 0.5;
        o_result = v_color * texture(u_texture, uv);
        //o_result = vec4(uv.x, uv.y, 0, 1.0);
    }
     else {
        // Unhandled particle kind
        o_result = vec4(1, 0, 0, 1);
    }
}

`