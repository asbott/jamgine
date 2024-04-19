# GPU-Accelerated Particle Emitter

![](/repo/emitter_v1_smoke.gif)

Currently in a very early state and in active development.

---
Here's a video with more action (click for youtube link):

<a href="https://www.youtube.com/watch?v=ZzpI29KnuVY">
    <img src="https://img.youtube.com/vi/ZzpI29KnuVY/0.jpg" alt="Youtube Video" style="width: 100%;">
</a>

## TODO LIST
- Spawn Area
    - Visualize with gizmos
    -  Area shapes
        - Square (p, sz, euler)
        - Circle (p, sz, euler)
        - Cube (p, sz, euler)
        - Sphere (p, euler)
        - Point (p)
    - Spawn modes
        - From center out
        - From out to center
        - Random
        - Some custom thing?
- Modular properties.
    - Instead of hard-coded properties, we can add/remove any properties which gets compiled into the compute shader. This is not just more performant but also allows for more fine-grained control.
    - Example: If I want particles to start at a certain/random rotation I can make one property for that and then also an interpolation property so all particles rotate the same but look different.
- Texture pool - selects texture for each particle from a pool of textures
- Save to file, load from file
- Fix blending. 1 pass with multiply blending, depth writing ON but testing OFF.
- Toggleable HDR blur pass
    - Color data in particles is already HDR, just need to do a HDR pass.
- Keyframes
    - Not sure yet how to implement this, if per property or per emitter?
    - CSS style keyframes.
- GLSL code injection
    - Load file with some glsl function to add an extra custom stage in the particle pipeline.
- 3D Particles
    - UV map & texture map?
    - Primitives: sphere, cube, pyramid
    - Custom shape?
    - Model loaded from disk (engine doesn't have model loading yet)
- Optimize
    - Cache computations where possible
    - Limit "max_particles" to emission_rate * max_lifetime
    - Don't use highp float?
    - Something makes it slow if a lot of particles are condensed in a small area
    - Allow explicit sync between compute & draw
    - Multiple configs for one emitter; shared resources SBO & VBO. 
        - Would require explicit synchronization between each compute/draw call