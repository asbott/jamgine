package justvk

import "core:fmt"
import "core:c"
import "core:log"

import vk "vendor:vulkan"
import "vendor:glfw"

Draw_Surface :: struct {
    dc : ^Device_Context,
    target_window : glfw.WindowHandle,

    vk_surface : vk.SurfaceKHR,
    vk_swap_chain : vk.SwapchainKHR,

    number_of_frames : int,

    targets : []Render_Target,
    frame_index : uint,

    extent : vk.Extent2D,
    format : vk.Format,

    frame_ready_semaphores : []vk.Semaphore,
    frame_ready_semaphore_index : int,
    
    render_pass : Render_Pass,

    is_first_frame_ever : bool,
    nothing_done_this_frame : bool,
}

make_draw_surface :: proc(window : glfw.WindowHandle, using dc := target_dc) -> ^Draw_Surface {
    
    surface := new(Draw_Surface);
    surface.dc = dc;
    surface.target_window = window;
    
    
    if glfw.CreateWindowSurface(vk_instance, window, nil, &surface.vk_surface) != .SUCCESS {
        panic("Failed creating window surface"); // TODO: return error
    }
    
    //
    // Check support
    required_device_exts := []cstring {
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
    };
    if !check_graphics_device_extensions(graphics_device, required_device_exts) {
        panic("Missing an extension for physical device"); // TODO: return error
    }
    swap_chain_details := get_swap_chain_support_details(graphics_device, surface.vk_surface);
    
    has_required_swap_chain_support := len(swap_chain_details.present_modes) > 0 && ((len(swap_chain_details.formats) > 0));
    
    if !has_required_swap_chain_support {
        panic("Missing required swap chain support") // TODO error
    }

    surface_format := choose_swap_chain_format(swap_chain_details.formats);

    width, height := glfw.GetWindowSize(window);

    resize_draw_surface(surface, cast(uint)width, cast(uint)height);
    
    surface.is_first_frame_ever = true;
    surface.nothing_done_this_frame = true;

    log.debug("Created a draw surface");

    return surface;
}
destroy_draw_surface :: proc(surface : ^Draw_Surface) {
    using surface.dc;
    vk.DeviceWaitIdle(vk_device);

    for sem in surface.frame_ready_semaphores {
        destroy_semaphore(sem, surface.dc);
    }

    for target in surface.targets {
        destroy_render_target(target);
    }

    vk.DestroySwapchainKHR(vk_device, surface.vk_swap_chain, nil);
    vk.DestroySurfaceKHR(vk_instance, surface.vk_surface, nil);

    delete(surface.targets);
    delete(surface.frame_ready_semaphores);
    free(surface);
}
resize_draw_surface :: proc(surface : ^Draw_Surface, width : uint, height : uint) {
    using surface.dc;

    vk.DeviceWaitIdle(vk_device);

    if surface.vk_swap_chain != 0 {
        
        for target in surface.targets {
            destroy_render_target(target);
        }
        vk.DestroySwapchainKHR(vk_device, surface.vk_swap_chain, nil);
    }
    swap_chain_details := get_swap_chain_support_details(graphics_device, surface.vk_surface);
    
    surface_format := choose_swap_chain_format(swap_chain_details.formats);
    present_mode := choose_swap_chain_present_mode(swap_chain_details.present_modes);
    extent := choose_swap_extent(swap_chain_details.capabilities, surface.target_window);
    
    image_count :u32= swap_chain_details.capabilities.minImageCount + 1;
    if (swap_chain_details.capabilities.maxImageCount > 0 && image_count > swap_chain_details.capabilities.maxImageCount) {
        image_count = swap_chain_details.capabilities.maxImageCount;
    }
    sc_create_info : vk.SwapchainCreateInfoKHR;
    sc_create_info.sType = .SWAPCHAIN_CREATE_INFO_KHR;
    sc_create_info.surface = surface.vk_surface;
    sc_create_info.minImageCount = image_count;
    sc_create_info.imageFormat = surface_format.format;
    sc_create_info.imageColorSpace = surface_format.colorSpace;
    sc_create_info.imageExtent = extent;
    
    sc_create_info.imageArrayLayers = 1;
    sc_create_info.imageUsage = {.COLOR_ATTACHMENT}
    indices := []u32{graphics_family, present_family};
    if (graphics_family != present_family) {
        sc_create_info.imageSharingMode = .CONCURRENT;
        sc_create_info.queueFamilyIndexCount = 2;
        sc_create_info.pQueueFamilyIndices = slice_to_multi_ptr(indices);
    } else {
        sc_create_info.imageSharingMode = .EXCLUSIVE;
        sc_create_info.queueFamilyIndexCount = 0;
        sc_create_info.pQueueFamilyIndices = nil;
    }
    sc_create_info.preTransform = swap_chain_details.capabilities.currentTransform;
    sc_create_info.compositeAlpha = {.OPAQUE};
    sc_create_info.presentMode = present_mode;
    sc_create_info.clipped = true;
    sc_create_info.oldSwapchain = 0;
    
    err := vk.CreateSwapchainKHR(vk_device, &sc_create_info, nil, &surface.vk_swap_chain);
    if err != .SUCCESS {
        panic(fmt.tprintf("Failed creating swap chain (%s)\n", err));  // TODO: error
    }
    surface.extent = extent;
    surface.format = surface_format.format; 
    
    vk.GetSwapchainImagesKHR(vk_device, surface.vk_swap_chain, &image_count, nil);
    swap_chain_images := make([]vk.Image, image_count);
    defer delete(swap_chain_images);
    vk.GetSwapchainImagesKHR(vk_device, surface.vk_swap_chain, &image_count, slice_to_multi_ptr(swap_chain_images));

    surface.number_of_frames = cast(int)image_count;

    if surface.targets == nil do surface.targets = make([]Render_Target, len(swap_chain_images));
    if surface.frame_ready_semaphores == nil {
        surface.frame_ready_semaphores = make([]vk.Semaphore, surface.number_of_frames * 3);

        for s, i in surface.frame_ready_semaphores {
            surface.frame_ready_semaphores[i] = make_semaphore(surface.dc);
        }
    }
    
    for img, i in swap_chain_images {
        surface.targets[i] = make_render_target(cast(int)width, cast(int)height, {img}, surface.format, .PRESENT_SRC_KHR, .COLOR_ATTACHMENT_OPTIMAL);
        transition_image_layout(img, surface.format, .UNDEFINED, .PRESENT_SRC_KHR, dc=surface.dc);
    }

    surface.render_pass = surface.targets[0].render_pass;



    log.infof("Created a swap chain with extent '%i, %i'", width, height);
}


choose_swap_chain_format :: proc(formats : []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
    for available in formats {
        if (available.format == .R8G8B8A8_SRGB && available.colorSpace == .SRGB_NONLINEAR) {
            return available;
        } else if (available.format == .B8G8R8A8_SRGB && available.colorSpace == .SRGB_NONLINEAR) {
            return available;
        }
    }
    return formats[0];
}

choose_swap_chain_present_mode :: proc(modes : []vk.PresentModeKHR) -> vk.PresentModeKHR {
    for available in modes {
        if (available == .MAILBOX) {
            return available;
        }
    }

    return .FIFO; // Always present
}

choose_swap_extent :: proc(capabilities : vk.SurfaceCapabilitiesKHR, target_window : glfw.WindowHandle = nil) -> vk.Extent2D {
    if (capabilities.currentExtent.width != c.UINT32_MAX) {
        return capabilities.currentExtent;
    } else if (target_window != nil) {
        width, height := glfw.GetFramebufferSize(target_window);

        actual_extent := vk.Extent2D {u32(width), u32(height)};

        actual_extent.width  = clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
        actual_extent.height = clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);

        return capabilities.currentExtent;
    } else {
        panic("Unimplemented"); // Not sure what would need to be done here or if it's even possible to get here
    }
}


begin_draw_surface :: proc(pipeline : ^Pipeline, surface : ^Draw_Surface) {
    using pipeline.dc;

    if surface.is_first_frame_ever {
        retrieve_next_target_in_surface(surface);
    }

    // If it's the first draw since presenting, we need those draw operations to 
    // wait for the retrieved image from the swap chain to be ready for drawing.
    if surface.nothing_done_this_frame {
        sem := surface.frame_ready_semaphores[surface.frame_ready_semaphore_index];
        append(&pipeline.wait_semaphores, sem);
    }
    
    begin_draw(pipeline, surface.targets[surface.frame_index]);

    surface.nothing_done_this_frame = false;
}

present_surface :: proc(surface : ^Draw_Surface) {
    using surface.dc;

    if surface.nothing_done_this_frame do return; // Nothing to present.

    swap_chains : []vk.SwapchainKHR = { surface.vk_swap_chain };
    present_info : vk.PresentInfoKHR;
    present_info.sType = .PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = 0; // #Sync
    present_info.swapchainCount = cast(u32)len(swap_chains);
    present_info.pSwapchains = slice_to_multi_ptr(swap_chains);
    present_info.pImageIndices = cast(^u32)&surface.frame_index;
    present_info.pResults = nil;
    vk.QueuePresentKHR(queues.present, &present_info);

    retrieve_next_target_in_surface(surface);
}

retrieve_next_target_in_surface :: proc(surface : ^Draw_Surface) {
    using surface.dc;
    surface.frame_ready_semaphore_index = (surface.frame_ready_semaphore_index + 1) % len(surface.frame_ready_semaphores);
    sem := surface.frame_ready_semaphores[surface.frame_ready_semaphore_index];
    result := vk.AcquireNextImageKHR(vk_device, surface.vk_swap_chain, c.UINT64_MAX, sem, 0, cast(^u32)&surface.frame_index);
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        width, height := glfw.GetWindowSize(surface.target_window);
        resize_draw_surface(surface, cast(uint)width, cast(uint)height);
        retrieve_next_target_in_surface(surface);
        return;
    } else if result != .SUCCESS {
        panic("Failed retrieve next image");
    }
    surface.is_first_frame_ever = false;
    surface.nothing_done_this_frame = true;
}