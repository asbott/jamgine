# Immediate Mode GUI

Made using my vulkan backend.

## API Example


```
igui.begin_window("My Window");

igui.label("Hey there", color=gfx.GREEN);

@(static)
f32_value : f32;
igui.f32_drag("Float value: ", &f32_value);

if igui.button("Unset") {
    f32_value = 0;
}

igui.end_window();
``` 
Above code results in:

![](/repo/simple_example.gif)

## Showcase
![](/repo/immgui.gif)

- Movable windows with auto-formatted widgets
- Classic GUI behaviour & Input handling
- Most basic widgets to do anything
- Extremely modular (everything is just panels with flags)

![](/repo/immgui_emitters_example.gif)

## TODO LIST
- Improve Text input widget
    - Smooth caret
    - Text select with mouse or SHIFT+left/right 
    - Clipboard copy, paste, cut
- Smooth scroll
- Scroll sliders/drags?
- HSV color picker widget
- Push ID scope, to avoid needing to concatenate every single string with an ID (#Speed!)
- Set Minimum size when resize
- Combo list
- Angle picker (Circle with line, drag, display degrees)
- Click on slider should move handle there
- Text box
- Stylize widgets
- Style editor
- Fix Bugs/Issues
    - Resize areas blocked by scrollbars
    - Mouse scroll blocked when any widget hovered (use CAPTURE_SCROLL flag)
    - Int drags are wonky (no decimal place interpolation)
    - Window secondary focus wonky on drag widgets & release outside window
    - Since titlebar ignores input, you cant drag there if there is a widget underneath.
        Should do another solution than just ignore input. Maybe like a HOOK flag which
        makes movement happen on parent of widget instead of the active widget.
    - Fix wobbliness (looks like widgets gets drawn one frame after parent window)
    - Make text labels cause overflow (expand content min/max).
    - Does lots of unecessary draw commands. Optimize.
        - If we give imm_gui its own Imm context it could have a pipeline active the whole
          frame and we wouldnt need to defer draw commands and can isntead draw directly
          to a render target which itself is drawn to screen with draw().
    - Columns waste space on right. More noticable with many columns.
    - Column spacing overall is off
- Render text to an atlas, clear & resize(?) when full
- Serialize
    - We already have a solid serialization system but the only problem is
      that widget state is stored in a map and I havent found a way to serialize
      maps yet.
- Image widgets
- Image button
- Fill texture (panel with texture as color)
- Instead of hardcoded offset IDs use the parent id as seed and generate random IDs