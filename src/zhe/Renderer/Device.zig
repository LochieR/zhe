const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw.zig");
const builtin = @import("builtin");

const utils = @import("../Utils/Utils.zig");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
    @cInclude("GLFW/glfw3native.h");
});

const Instance = @import("Instance.zig").Instance;
const Swapchain = @import("Swapchain.zig").Swapchain;
const SwapchainInfo = @import("Swapchain.zig").SwapchainInfo;
const RenderPass = @import("RenderPass.zig").RenderPass;
const RenderPassInfo = @import("RenderPass.zig").RenderPassInfo;
const GraphicsPipeline = @import("GraphicsPipeline.zig").GraphicsPipeline;
const GraphicsPipelineInfo = @import("GraphicsPipeline.zig").GraphicsPipelineInfo;

pub const DeviceError = error {
    NoValidGPUs,
    NoSuitableMemoryType,
    InvalidPresentMode
};

const deviceExtensions = [_][:0]const u8 {
    vk.extensions.khr_swapchain.name
};

const QueueFamilyIndices = struct {
    graphics_family: u32 = std.math.maxInt(u32),
    present_family: u32 = std.math.maxInt(u32),

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_family != std.math.maxInt(u32) and self.present_family != std.math.maxInt(u32);
    }
};

const querySwapchainSupport = @import("Swapchain.zig").querySwapchainSupport;
const chooseSwapSurfaceFormat = @import("Swapchain.zig").chooseSwapSurfaceFormat;
const chooseSwapPresentMode = @import("Swapchain.zig").chooseSwapPresentMode;
const presentModeSupported = @import("Swapchain.zig").presentModeSupported;
const chooseSwapExtent = @import("Swapchain.zig").chooseSwapExtent;
const findDepthFormat = @import("Swapchain.zig").findDepthFormat;
const convertFormat = @import("Swapchain.zig").convertFormat;

const MaxFramesInFlight = @import("Instance.zig").MaxFramesInFlight;

pub const Device = struct {

    allocator: std.mem.Allocator,

    instance: *const Instance,

    physical_device: vk.PhysicalDevice,
    device: vk.DeviceProxy,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,

    command_pool: vk.CommandPool,
    descriptor_pool: vk.DescriptorPool,

    frame_index: u32,

    skip_frame: bool,

    image_available_semaphores: [MaxFramesInFlight]vk.Semaphore,
    render_finished_semaphores: [MaxFramesInFlight]vk.Semaphore,
    in_flight_fences: [MaxFramesInFlight]vk.Fence,

    pub fn createSwapchain(self: *Device, swapchain_info: *const SwapchainInfo) !Swapchain {
        const swapchain_support = try querySwapchainSupport(self.instance.instance, self.allocator, self.physical_device, self.instance.surface);
        defer self.allocator.free(swapchain_support.formats);
        defer self.allocator.free(swapchain_support.present_modes);

        const surface_format = chooseSwapSurfaceFormat(swapchain_support.formats);
        const extent = chooseSwapExtent(@ptrCast(self.instance.window), swapchain_support.capabilities);

        const present_mode: vk.PresentModeKHR = switch (swapchain_info.present_mode) {
            .swapchain_default, .mailbox_or_fifo => chooseSwapPresentMode(swapchain_support.present_modes),
            .mailbox => vk.PresentModeKHR.mailbox_khr,
            .fifo => vk.PresentModeKHR.fifo_khr,
            .immediate => vk.PresentModeKHR.immediate_khr
        };
        if (!presentModeSupported(swapchain_support.present_modes, present_mode)) {
            return error.InvalidPresentMode;
        }

        var swapchain_image_count = swapchain_support.capabilities.min_image_count + 1;
        if (swapchain_support.capabilities.max_image_count > 0 and swapchain_image_count > swapchain_support.capabilities.max_image_count) {
            swapchain_image_count = swapchain_support.capabilities.max_image_count;
        }

        var create_info = vk.SwapchainCreateInfoKHR{
            .surface = self.instance.surface,
            .min_image_count = swapchain_image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .old_swapchain = .null_handle,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true, .sampled_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = swapchain_support.capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true
        };

        const indices = try findQueueFamilies(self.instance.instance, self.allocator, self.physical_device, self.instance.surface);
        const queue_families = [_]u32 { indices.graphics_family, indices.present_family };

        if (indices.graphics_family != indices.present_family) {
            create_info.image_sharing_mode = .concurrent;
            create_info.queue_family_index_count = 2;
            create_info.p_queue_family_indices = &queue_families;
        } else {
            create_info.image_sharing_mode = .exclusive;
        }

        const swapchain = try self.device.createSwapchainKHR(&create_info, self.instance.vk_allocator);
        errdefer self.device.destroySwapchainKHR(swapchain, self.instance.vk_allocator);

        var swapchain_obj = Swapchain{
            .allocator = self.allocator,
            .device = self,
            .swapchain_info = swapchain_info.*,
            .extent = extent,
            .swapchain = swapchain,
            .swapchain_image_count = swapchain_image_count,
            .swapchain_image_format = surface_format.format,
            .attachments = std.array_list.Managed(Swapchain.Attachment).init(self.allocator),
            .image_index = 0
        };

        _ = try self.device.getSwapchainImagesKHR(swapchain_obj.swapchain, &swapchain_obj.swapchain_image_count, null);

        const swapchain_images = try self.allocator.alloc(vk.Image, swapchain_obj.swapchain_image_count);
        defer self.allocator.free(swapchain_images);

        _ = try self.device.getSwapchainImagesKHR(swapchain_obj.swapchain, &swapchain_obj.swapchain_image_count, swapchain_images.ptr);

        for (0..swapchain_info.attachments.len) |attachment_index| {
            const format = swapchain_info.attachments[attachment_index];
            var attachment: Swapchain.Attachment = .{
                .images = std.array_list.Managed(vk.Image).init(self.allocator),
                .views = std.array_list.Managed(vk.ImageView).init(self.allocator),
                .memory = std.array_list.Managed(vk.DeviceMemory).init(self.allocator),
                .format = .undefined,
                .usage = .{}
            };

            switch (format) {
                .swapchain_color_default => {
                    attachment.format = surface_format.format;
                    try attachment.images.resize(swapchain_images.len);
                    @memcpy(attachment.images.items, swapchain_images);
                    try attachment.views.resize(attachment.images.items.len);
                    attachment.usage = .{ .color_attachment_bit = true };

                    for (0..attachment.images.items.len) |i| {
                        const view_info = vk.ImageViewCreateInfo{
                            .s_type = .image_view_create_info,
                            .image = attachment.images.items[i],
                            .view_type = .@"2d",
                            .format = attachment.format,
                            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                            .subresource_range = vk.ImageSubresourceRange{
                                .aspect_mask = .{ .color_bit = true },
                                .base_mip_level = 0,
                                .level_count = 1,
                                .base_array_layer = 0,
                                .layer_count = 1
                            }
                        };

                        attachment.views.items[i] = try self.device.createImageView(&view_info, self.instance.vk_allocator);
                        errdefer self.device.destroyImageView(attachment.views.items[i], self.instance.vk_allocator);
                    }
                },
                .swapchain_depth_default, .d32_sfloat => {
                    if (format == .swapchain_depth_default) {
                        attachment.format = try findDepthFormat(self.instance.instance, self.physical_device);
                    } else {
                        attachment.format = convertFormat(format);
                    }
                    attachment.usage = .{ .depth_stencil_attachment_bit = true };

                    try attachment.images.resize(swapchain_obj.swapchain_image_count);
                    try attachment.views.resize(swapchain_obj.swapchain_image_count);
                    try attachment.memory.resize(swapchain_obj.swapchain_image_count);

                    for (0..swapchain_obj.swapchain_image_count) |i| {
                        const image_info = vk.ImageCreateInfo{
                            .s_type = .image_create_info,
                            .image_type = .@"2d",
                            .extent = vk.Extent3D{
                                .width = extent.width,
                                .height = extent.height,
                                .depth = 1
                            },
                            .mip_levels = 1,
                            .array_layers = 1,
                            .format = attachment.format,
                            .tiling = .optimal,
                            .initial_layout = .undefined,
                            .usage = attachment.usage,
                            .samples = .{ .@"1_bit" = true },
                            .sharing_mode = .exclusive
                        };

                        attachment.images.items[i] = try self.device.createImage(&image_info, self.instance.vk_allocator);
                        errdefer self.device.destroyImage(attachment.images.items[i], self.instance.vk_allocator);

                        const mem_requirements: vk.MemoryRequirements = self.device.getImageMemoryRequirements(attachment.images.items[i]);

                        const alloc_info = vk.MemoryAllocateInfo{
                            .s_type = .memory_allocate_info,
                            .allocation_size = mem_requirements.size,
                            .memory_type_index = try findMemoryType(self.instance.instance, self.physical_device, mem_requirements.memory_type_bits, .{ .device_local_bit = true })
                        };

                        attachment.memory.items[i] = try self.device.allocateMemory(&alloc_info, self.instance.vk_allocator);
                        errdefer self.device.freeMemory(attachment.memory.items[i], self.instance.vk_allocator);

                        try self.device.bindImageMemory(attachment.images.items[i], attachment.memory.items[i], 0);

                        const view_info = vk.ImageViewCreateInfo{
                            .s_type = .image_view_create_info,
                            .image = attachment.images.items[i],
                            .view_type = .@"2d",
                            .format = attachment.format,
                            .subresource_range = vk.ImageSubresourceRange{
                                .aspect_mask = .{ .depth_bit = true },
                                .base_mip_level = 0,
                                .level_count = 1,
                                .base_array_layer = 0,
                                .layer_count = 1
                            },
                            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                            .flags = .{},
                            .p_next = null
                        };

                        attachment.views.items[i] = try self.device.createImageView(&view_info, self.instance.vk_allocator);
                        errdefer self.device.destroyImageView(attachment.views.items[i], self.instance.vk_allocator);
                    }
                },
                .r8_uint, .r16_uint, .r32_uint, .r64_uint,
                .r8_sint, .r16_sint, .r32_sint, .r64_sint,
                .r8_unorm, .r16_unorm, .r32_sfloat, .bgra8_unorm,
                .rgba8_unorm, .rgba16_sfloat, .rgba32_sfloat => {
                    attachment.format = convertFormat(format);
                    attachment.usage = .{ .color_attachment_bit = true };

                    try attachment.images.resize(swapchain_obj.swapchain_image_count);
                    try attachment.views.resize(swapchain_obj.swapchain_image_count);
                    try attachment.memory.resize(swapchain_obj.swapchain_image_count);

                    for (0..swapchain_obj.swapchain_image_count) |i| {
                        const image_info = vk.ImageCreateInfo{
                            .s_type = .image_create_info,
                            .image_type = .@"2d",
                            .extent = vk.Extent3D{
                                .width = extent.width,
                                .height = extent.height,
                                .depth = 1
                            },
                            .mip_levels = 1,
                            .array_layers = 1,
                            .format = attachment.format,
                            .tiling = .optimal,
                            .initial_layout = .undefined,
                            .usage = attachment.usage,
                            .samples = .{ .@"1_bit" = true },
                            .sharing_mode = .exclusive
                        };

                        attachment.images.items[i] = try self.device.createImage(&image_info, self.instance.vk_allocator);
                        errdefer self.device.destroyImage(attachment.images.items[i], self.instance.vk_allocator);

                        const mem_requirements: vk.MemoryRequirements = self.device.getImageMemoryRequirements(attachment.images.items[i]);

                        const alloc_info = vk.MemoryAllocateInfo{
                            .s_type = .memory_allocate_info,
                            .allocation_size = mem_requirements.size,
                            .memory_type_index = try findMemoryType(self.instance.instance, self.physical_device, mem_requirements.memory_type_bits, .{ .device_local_bit = true })
                        };

                        attachment.memory.items[i] = try self.device.allocateMemory(&alloc_info, self.instance.vk_allocator);
                        errdefer self.device.freeMemory(attachment.memory.items[i], self.instance.vk_allocator);

                        try self.device.bindImageMemory(attachment.images.items[i], attachment.memory.items[i], 0);

                        const view_info = vk.ImageViewCreateInfo{
                            .s_type = .image_view_create_info,
                            .image = attachment.images.items[i],
                            .view_type = .@"2d",
                            .format = attachment.format,
                            .subresource_range = vk.ImageSubresourceRange{
                                .aspect_mask = .{ .color_bit = true },
                                .base_mip_level = 0,
                                .level_count = 1,
                                .base_array_layer = 0,
                                .layer_count = 1
                            },
                            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                            .flags = .{},
                            .p_next = null
                        };

                        attachment.views.items[i] = try self.device.createImageView(&view_info, self.instance.vk_allocator);
                        errdefer self.device.destroyImageView(attachment.views.items[i], self.instance.vk_allocator);
                    }
                }
            }
            try swapchain_obj.attachments.append(attachment);
        }

        return swapchain_obj;
    }

    pub fn destroySwapchain(self: *Device, swapchain: *Swapchain) void {
        for (swapchain.attachments.items) |attachment| {
            for (attachment.views.items) |view| {
                self.device.destroyImageView(view, self.instance.vk_allocator);
            }

            if (attachment.memory.items.len != 0) {
                for (0..attachment.images.items.len) |i| {
                    self.device.destroyImage(attachment.images.items[i], self.instance.vk_allocator);
                    self.device.freeMemory(attachment.memory.items[i], self.instance.vk_allocator);
                }
            }

            attachment.images.deinit();
            attachment.views.deinit();
            attachment.memory.deinit();
        }
        swapchain.attachments.deinit();

        self.device.destroySwapchainKHR(swapchain.swapchain, self.instance.vk_allocator);
    }

    pub fn createRenderPass(self: *Device, swapchain: *Swapchain, render_pass_info: *const RenderPassInfo) !RenderPass {
        var render_pass = RenderPass{
            .allocator = self.allocator,
            .device = self,
            .swapchain = swapchain,
            .pass_info = render_pass_info.*,
            .render_pass = .null_handle,
            .framebuffers = std.array_list.Managed(vk.Framebuffer).init(self.allocator),
            .attachment_indices = std.array_list.Managed(u32).init(self.allocator)
        };
        try render_pass.recreate();

        return render_pass;
    }

    pub fn destroyRenderPass(self: *Device, render_pass: *RenderPass) void {
        _ = self;
        render_pass.dispose();
    }

    pub fn createGraphicsPipeline(self: *Device, pipeline_info: *const GraphicsPipelineInfo) !GraphicsPipeline {
        const vertex_code = try pipeline_info.vertex_shader.getShaderCode(&self.allocator);
        defer self.allocator.free(vertex_code);

        const pixel_code = try pipeline_info.pixel_shader.getShaderCode(&self.allocator);
        defer self.allocator.free(pixel_code);

        const vertex_module_create_info = vk.ShaderModuleCreateInfo{
            .s_type = .shader_module_create_info,
            .code_size = vertex_code.len,
            .p_code = @ptrCast(@alignCast(vertex_code.ptr)),
        };

        const vertex_shader_module = try self.device.createShaderModule(&vertex_module_create_info, self.instance.vk_allocator);
        errdefer self.device.destroyShaderModule(vertex_shader_module, self.instance.vk_allocator);

        const pixel_module_create_info = vk.ShaderModuleCreateInfo{
            .s_type = .shader_module_create_info,
            .code_size = pixel_code.len,
            .p_code = @ptrCast(@alignCast(pixel_code.ptr))
        };

        const pixel_shader_module = try self.device.createShaderModule(&pixel_module_create_info, self.instance.vk_allocator);
        errdefer self.device.destroyShaderModule(pixel_shader_module, self.instance.vk_allocator);

        return undefined;
    }

    pub fn getPhysicalDeviceName(self: *const Device, allocator: std.mem.Allocator) ![:0]const u8 {
        const properties = self.instance.instance.getPhysicalDeviceProperties(self.physical_device);
        const slice: []const u8 = std.mem.sliceTo(&properties.device_name, 0);
        const name = try allocator.alloc(u8, slice.len);
        std.mem.copyForwards(u8, name, slice);
        return @ptrCast(name);
    }

};

pub fn pickPhysicalDevice(instance: vk.InstanceProxy, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !vk.PhysicalDevice {
    const devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(devices);

    for (devices) |device| {
        if (try isDeviceSuitable(instance, allocator, device, surface)) {
            return device;
        }
    }

    return error.NoValidGPUs;
}

fn isDeviceSuitable(instance: vk.InstanceProxy, allocator: std.mem.Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    const indices = try findQueueFamilies(instance, allocator, device, surface);

    const extensions_supported = try checkDeviceExtensionSupport(instance, allocator, device);

    var swapchainAdequate = false;
    if (extensions_supported) {
        const swapchain_support = try querySwapchainSupport(instance, allocator, device, surface);
        swapchainAdequate = swapchain_support.formats.len != 0 and swapchain_support.present_modes.len != 0;

        allocator.free(swapchain_support.formats);
        allocator.free(swapchain_support.present_modes);
    }

    const features = instance.getPhysicalDeviceFeatures(device);

    return
        indices.isComplete() and
        extensions_supported and
        swapchainAdequate and
        features.sampler_anisotropy == .true;
}

pub fn findQueueFamilies(instance: vk.InstanceProxy, allocator: std.mem.Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilyIndices {
    var indices: QueueFamilyIndices = .{};

    const queue_family_properties = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, allocator);
    defer allocator.free(queue_family_properties);

    var i: u32 = 0;
    for (queue_family_properties) |queue_family| {
        if (queue_family.queue_flags.graphics_bit) {
            indices.graphics_family = i;
        }

        const present_support = try instance.getPhysicalDeviceSurfaceSupportKHR(device, i, surface);
        
        if (present_support == .true) {
            indices.present_family = i;
        }

        if (indices.isComplete()) {
            break;
        }

        i += 1;
    }

    return indices;
}

fn checkDeviceExtensionSupport(instance: vk.InstanceProxy, allocator: std.mem.Allocator, device: vk.PhysicalDevice) !bool {
    const available_extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(device, null, allocator);
    defer allocator.free(available_extensions);

    var required_extensions = std.StringHashMap(void).init(allocator);
    defer required_extensions.deinit();

    for (deviceExtensions) |ext| {
        try required_extensions.put(ext, {});
    }

    for (available_extensions) |*ext| {
        const ext_name = std.mem.sliceTo(&ext.extension_name, 0);
        _ = required_extensions.remove(ext_name);
    }

    return required_extensions.count() == 0;
}

pub fn findMemoryType(instance: vk.InstanceProxy, physical_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const mem_properties = instance.getPhysicalDeviceMemoryProperties(physical_device);

    for (0..mem_properties.memory_type_count) |i| {
        if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and mem_properties.memory_types[i].property_flags.intersect(properties) == properties) {
            return @intCast(i);
        }
    }

    return error.NoSuitableMemoryType;
}
