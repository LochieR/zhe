const std = @import("std");
const vk = @import("vulkan");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
});

const Device = @import("Device.zig").Device;

const MaxFramesInFlight = @import("Instance.zig").MaxFramesInFlight;

pub const SwapchainError = error{
    NoSupportedDepthFormat
};

pub const SwapchainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR
};

pub const AttachmentFormat = enum(u8) {
    swapchain_color_default = 0, 
    swapchain_depth_default = 1, 
    
    r8_uint,
    r16_uint,
    r32_uint,
    r64_uint,
    r8_sint,
    r16_sint,
    r32_sint,
    r64_sint,
    r8_unorm,
    r16_unorm,
    r32_sfloat,
    bgra8_unorm,
    rgba8_unorm,
    rgba16_sfloat,
    rgba32_sfloat,
    
    d32_sfloat    
};

pub const PresentMode = enum(u8) {
    swapchain_default = 0,
    mailbox,
    fifo,
    mailbox_or_fifo,
    immediate
};

pub const SwapchainInfo = struct {
    attachments: []const AttachmentFormat,
    present_mode: PresentMode
};

pub const Swapchain = struct {
    pub const Attachment = struct {
        images: std.array_list.Managed(vk.Image),
        views: std.array_list.Managed(vk.ImageView),
        memory: std.array_list.Managed(vk.DeviceMemory),
        format: vk.Format,
        usage: vk.ImageUsageFlags
    };

    allocator: std.mem.Allocator,
    device: *Device,

    swapchain_info: SwapchainInfo,

    swapchain: vk.SwapchainKHR,
    swapchain_image_format: vk.Format,
    extent: vk.Extent2D,

    swapchain_image_count: u32,

    attachments: std.array_list.Managed(Attachment),

    image_index: u32,

    pub fn acquireNextImage(self: *Swapchain) !void {
        _ = try self.device.device.waitForFences(1, self.device.in_flight_fences[self.device.frame_index..(self.device.frame_index + 1)].ptr, .true, std.math.maxInt(u64));

        var swapchain_recreate = false;
        const result = try self.device.device.acquireNextImageKHR(self.swapchain, std.math.maxInt(u64), self.device.image_available_semaphores[self.device.frame_index], .null_handle);// catch |err| {
        //    if (err == error.OutOfDateKHR) {
        //        swapchain_recreate = true;
        //    }
        //};
        if (result.result == .suboptimal_khr) {
            swapchain_recreate = true;
        }

        if (swapchain_recreate) {
            try self.recreateSwapchain();

            self.device.skip_frame = true;
            return;
        }

        self.image_index = result.image_index;

        try self.device.device.resetFences(1, self.device.in_flight_fences[self.device.frame_index..(self.device.frame_index + 1)].ptr);
    }

    pub fn recreateSwapchain(self: *Swapchain) !void {
        _ = self;
    }

    pub fn getDefaultDepthAttachmentFormat(self: *Swapchain) !vk.Format {
        return try findDepthFormat(self.device.instance.instance, self.device.physical_device);
    }

    pub fn getAttachmentViews(self: *Swapchain, allocator: *std.mem.Allocator, image_index: u32) !std.ArrayList(vk.ImageView) {
        var result = std.ArrayList(vk.ImageView).init(allocator);
        
        for (self.attachments.items) |attachment| {
            try result.append(attachment.views[image_index]);
        }

        return result;
    }

    pub fn getAttachmentViewsWithIndices(self: *Swapchain, allocator: *std.mem.Allocator, indices: []u32, image_index: u32) !std.array_list.Managed(vk.ImageView) {
        var result = std.array_list.Managed(vk.ImageView).init(allocator.*);
        try result.resize(indices.len);
        for (indices, 0..) |idx, i| {
            result.items[i] = self.attachments.items[idx].views.items[image_index];
        }

        return result;
    }
};

pub fn querySwapchainSupport(instance: vk.InstanceProxy, allocator: std.mem.Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !SwapchainSupportDetails {
    var details: SwapchainSupportDetails = undefined;

    details.capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(device, surface);
    details.formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(device, surface, allocator);
    details.present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(device, surface, allocator);

    return details;
}

pub fn chooseSwapSurfaceFormat(formats: []vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |available_format| {
        if (available_format.format == .b8g8r8a8_unorm and available_format.color_space == .srgb_nonlinear_khr) {
            return available_format;
        }
    }

    return formats[0];
}

pub fn chooseSwapPresentMode(available_present_modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    for (available_present_modes) |present_mode| {
        if (present_mode == .mailbox_khr) {
            return present_mode;
        }
    }

    return vk.PresentModeKHR.fifo_khr;
}

pub fn presentModeSupported(available: []vk.PresentModeKHR, mode: vk.PresentModeKHR) bool {
    for (available) |present_mode| {
        if (present_mode == mode) {
            return true;
        }
    }

    return false;
}

pub fn chooseSwapExtent(window: *c.GLFWwindow, capabilities: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u8)) {
        return capabilities.current_extent;
    } else {
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.glfwGetFramebufferSize(@ptrCast(window), &width, &height);

        var actual_extent = vk.Extent2D{ .width = @intCast(width), .height = @intCast(height) };

        actual_extent.width = std.math.clamp(actual_extent.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width);
        actual_extent.height = std.math.clamp(actual_extent.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height);

        return actual_extent;
    }
}

pub fn findDepthFormat(instance: vk.InstanceProxy, physical_device: vk.PhysicalDevice) !vk.Format {
    return try findSupportedFormat(instance, physical_device, &[_]vk.Format{ .d32_sfloat, .d32_sfloat_s8_uint, .d24_unorm_s8_uint }, .optimal, .{ .depth_stencil_attachment_bit = true });
}

pub fn findSupportedFormat(instance: vk.InstanceProxy, physical_device: vk.PhysicalDevice, candidates: []const vk.Format, tiling: vk.ImageTiling, features: vk.FormatFeatureFlags) !vk.Format {
    for (candidates) |format| {
        var properties: vk.FormatProperties = instance.getPhysicalDeviceFormatProperties(physical_device, format);

        if (tiling == .linear and properties.linear_tiling_features.intersect(features) == features) {
            return format;
        } else if (tiling == .optimal and properties.optimal_tiling_features.intersect(features) == features) {
            return format;
        }
    }

    return error.NoSupportedDepthFormat;
}

pub fn convertFormat(format: AttachmentFormat) vk.Format {
    return switch (format) {
        .swapchain_color_default => .undefined,
        .swapchain_depth_default => .undefined,
        .r8_uint => .r8_uint,
        .r16_uint => .r16_uint,
        .r32_uint => .r32_uint,
        .r64_uint => .r64_uint,
        .r8_sint => .r8_sint,
        .r16_sint => .r16_sint,
        .r32_sint => .r32_sint,
        .r64_sint => .r64_sint,
        .r8_unorm => .r8_unorm,
        .r16_unorm => .r16_unorm,
        .r32_sfloat => .r32_sfloat,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .rgba16_sfloat => .r16g16b16a16_sfloat,
        .rgba32_sfloat => .r32g32b32a32_sfloat,
        .d32_sfloat => .d32_sfloat,
    };
}
