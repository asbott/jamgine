# GPU-Accelerated Particle Emitter

Currently in a very early state and in active development.

![](/repo/emitter_v1_smoke.gif)

![](/repo/emitters_spawn_area.gif)
---
Here's a video with more action (click for youtube link):

<a href="https://www.youtube.com/watch?v=RQSNZNkTyAg ">
    <img src="https://img.youtube.com/vi/RQSNZNkTyAg/1.jpg" alt="Youtube Video" style="width: 100%;">
</a>

## TODO LIST
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
    - Maybe this could just be named % values and properties can select these for
      begin & start'
- Look over random distributions (mainly normal & extremes)
- GLSL code injection
    - Load file with some glsl function to add an extra custom stage in the particle pipeline.
    - We could inject custom code for spawn stage for more fine-tuned spawning.
- 3D Particles
    - UV map & texture map?
    - Primitives: sphere, cube, pyramid
    - Custom shape?
    - Model loaded from disk (engine doesn't have model loading yet)
- Optimize
    - Something makes emitter a bit slower when looping is enabled
    - Cache computations where possible
    - Allow explicit sync between compute & draw
    - Multiple configs for one emitter; shared SBO. 
        - Would require explicit synchronization between each compute/draw call
    - We could give an option when compiling the emitter to use up more vram to cache
      computations for particles which are the same throughout their lifetime such as
      constants, start_pos, particle_seed etc. Could drastically improve performance
      at the cost of a lot of vram when simulating many particles.
    - We can pack the Particle struct and save a lot of VRAM