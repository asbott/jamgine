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
![](../../repo/simple_example.gif)

## General Showcase
![](../../repo/immgui.gif)