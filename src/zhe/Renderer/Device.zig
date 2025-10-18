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
const PrimitiveTopology = @import("GraphicsPipeline.zig").PrimitiveTopology;
const ShaderStage = @import("ShaderLibrary.zig").ShaderStage;
const ShaderResourceType = @import("ShaderLibrary.zig").ShaderResourceType;
const Buffer = @import("Buffer.zig").Buffer;
const BufferType = @import("Buffer.zig").BufferType;
const CommandList = @import("CommandList.zig").CommandList;
const CommandScope = @import("CommandList.zig").CommandScope;
const CommandScopeType = @import("CommandList.zig").CommandScopeType;
const NativeCommand = @import("CommandList.zig").NativeCommand;
const NativeCommandVTable = @import("CommandList.zig").NativeCommandVTable;
const ShaderResource = @import("ShaderResource.zig").ShaderResource;
const ShaderResourceLayout = @import("ShaderResource.zig").ShaderResourceLayout;
const ResourceLayoutItem = @import("ShaderResource.zig").ResourceLayoutItem;

pub const DeviceError = error {
    NoValidGPUs,
    NoSuitableMemoryType,
    InvalidPresentMode,
    SubmitWhileRecording,
    NotSingleTimeCommands,
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

pub const CommandListData = struct {
    buffers: std.ArrayListUnmanaged(vk.CommandBuffer) = .{},
    types: std.ArrayListUnmanaged(CommandScopeType) = .{},
    render_passes: std.ArrayListUnmanaged(?*RenderPass) = .{},
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

    secondary_command_buffers: [MaxFramesInFlight]std.ArrayListUnmanaged(vk.CommandBuffer),
    used_secondary_command_buffer_count: [MaxFramesInFlight]u32,

    submitted_command_lists: [MaxFramesInFlight]std.ArrayListUnmanaged(CommandListData),

    frame_command_buffers: [MaxFramesInFlight]vk.CommandBuffer,

    frame_index: u32,

    skip_frame: bool,

    swapchain: ?Swapchain,

    image_available_semaphores: [MaxFramesInFlight]vk.Semaphore,
    render_finished_semaphores: std.ArrayListUnmanaged(vk.Semaphore),
    in_flight_fences: [MaxFramesInFlight]vk.Fence,

    pub fn beginFrame(self: *Device) !void {
        _ = try self.device.waitForFences(1, self.in_flight_fences[self.frame_index..(self.frame_index + 1)].ptr, .true, std.math.maxInt(u64));
        if (self.swapchain) |_| {
            try self.swapchain.?.acquireNextImage();
        }
        try self.device.resetFences(1, self.in_flight_fences[self.frame_index..(self.frame_index + 1)].ptr);
    }

    pub fn endFrame(self: *Device) !void {
        if (self.skip_frame) {
            self.skip_frame = false;
            try self.device.deviceWaitIdle();

            return;
        }

        const wait_stages = [_]vk.PipelineStageFlags { .{ .color_attachment_output_bit = true } };

        const begin_info = vk.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info
        };

        try self.device.beginCommandBuffer(self.frame_command_buffers[self.frame_index], &begin_info);

        for (self.submitted_command_lists[self.frame_index].items) |command_list| {
            for (0..command_list.types.items.len) |i| {
                const list_type = command_list.types.items[i];
                const render_pass = command_list.render_passes.items[i];

                if (list_type == .render_pass) {
                    const clear_values = [_]vk.ClearValue {
                        .{
                            .color = vk.ClearColorValue{ .float_32 = [_]f32 { 0.0, 0.0, 0.0, 0.0 } },
                        },
                        .{
                            .depth_stencil = vk.ClearDepthStencilValue{ .depth = 1.0, .stencil = 0 }
                        }
                    };

                    const render_pass_info = vk.RenderPassBeginInfo{
                        .s_type = .render_pass_begin_info,
                        .render_area = .{ .extent = self.swapchain.?.extent, .offset = .{ .x = 0, .y = 0 } },
                        .render_pass = render_pass.?.render_pass,
                        .framebuffer = render_pass.?.framebuffers.items[self.swapchain.?.image_index],
                        .clear_value_count = clear_values.len,
                        .p_clear_values = &clear_values,
                    };

                    self.device.cmdBeginRenderPass(self.frame_command_buffers[self.frame_index], &render_pass_info, .secondary_command_buffers);
                }

                self.device.cmdExecuteCommands(self.frame_command_buffers[self.frame_index], 1, command_list.buffers.items[i..(i + 1)].ptr);

                if (list_type == .render_pass) {
                    self.device.cmdEndRenderPass(self.frame_command_buffers[self.frame_index]);
                }
            }
        }

        try self.device.endCommandBuffer(self.frame_command_buffers[self.frame_index]);

        const submit = [_]vk.SubmitInfo {
            .{
                .s_type = .submit_info,
                .command_buffer_count = 1,
                .p_command_buffers = self.frame_command_buffers[self.frame_index..(self.frame_index + 1)].ptr,
                .wait_semaphore_count = 1,
                .p_wait_semaphores = self.image_available_semaphores[self.frame_index..(self.frame_index + 1)].ptr,
                .p_wait_dst_stage_mask = &wait_stages,
                .signal_semaphore_count = 1,
                .p_signal_semaphores = self.render_finished_semaphores.items[self.swapchain.?.image_index..(self.swapchain.?.image_index + 1)].ptr,
            }
        };

        try self.device.queueSubmit(self.graphics_queue, 1, &submit, self.in_flight_fences[self.frame_index]);

        const swapchains = [_]vk.SwapchainKHR { self.swapchain.?.swapchain };
        const image_indices = [_]u32 { self.swapchain.?.image_index };

        const present_info = vk.PresentInfoKHR{
            .s_type = .present_info_khr,
            .wait_semaphore_count = 1,
            .p_wait_semaphores = self.render_finished_semaphores.items[self.swapchain.?.image_index..(self.swapchain.?.image_index + 1)].ptr,
            .swapchain_count = 1,
            .p_swapchains = &swapchains,
            .p_image_indices = &image_indices,
        };

        const result = try self.device.queuePresentKHR(self.present_queue, &present_info);
        if (result == .suboptimal_khr) {
            try self.swapchain.?.recreateSwapchain();
        }

        for (0..self.submitted_command_lists[self.frame_index].items.len) |i| {
            self.submitted_command_lists[self.frame_index].items[i].buffers.deinit(self.allocator);
            self.submitted_command_lists[self.frame_index].items[i].render_passes.deinit(self.allocator);
            self.submitted_command_lists[self.frame_index].items[i].types.deinit(self.allocator);
        }

        self.submitted_command_lists[self.frame_index].clearRetainingCapacity();
        self.used_secondary_command_buffer_count[self.frame_index] = 0;

        self.frame_index = (self.frame_index + 1) % MaxFramesInFlight;
    }

    pub fn submitCommandList(self: *Device, command_list: *const CommandList) !void {
        if (self.skip_frame) {
            return;
        }

        if (command_list.is_recording) {
            return error.SubmitWhileRecording;
        }

        var command_list_data = CommandListData{};

        for (command_list.scopes.items) |scope| {
            if (scope.commands.items.len == 0) {
                continue;
            }

            var command_buffer: vk.CommandBuffer = .null_handle;

            if (self.used_secondary_command_buffer_count[self.frame_index] < self.secondary_command_buffers[self.frame_index].items.len) {
                command_buffer = self.secondary_command_buffers[self.frame_index].items[self.used_secondary_command_buffer_count[self.frame_index]];
                self.used_secondary_command_buffer_count[self.frame_index] += 1;
            } else {
                const alloc_info = vk.CommandBufferAllocateInfo{
                    .s_type = .command_buffer_allocate_info,
                    .command_pool = self.command_pool,
                    .command_buffer_count = 1,
                    .level = .secondary,
                };

                var temp_cmd = [_]vk.CommandBuffer { .null_handle };
                try self.device.allocateCommandBuffers(&alloc_info, &temp_cmd);

                command_buffer = temp_cmd[0];
                try self.secondary_command_buffers[self.frame_index].append(self.allocator, command_buffer);
                self.used_secondary_command_buffer_count[self.frame_index] += 1;
            }

            var inheritance_info = std.mem.zeroes(vk.CommandBufferInheritanceInfo);
            inheritance_info.s_type = .command_buffer_inheritance_info;

            var begin_info = std.mem.zeroes(vk.CommandBufferBeginInfo);
            begin_info.s_type = .command_buffer_begin_info;
            begin_info.p_inheritance_info = &inheritance_info;

            if (scope.scope_type == .render_pass) {
                if (scope.current_render_pass) |render_pass| {
                    inheritance_info.render_pass = render_pass.render_pass;
                    inheritance_info.framebuffer = render_pass.framebuffers.items[render_pass.swapchain.image_index];

                    begin_info.flags = .{ .render_pass_continue_bit = true };

                    try command_list_data.render_passes.append(self.allocator, render_pass);
                }
            }
            else {
                try command_list_data.render_passes.append(self.allocator, null);
            }

            try self.device.beginCommandBuffer(command_buffer, &begin_info);
            try self.executeCommandScope(command_buffer, &scope);
            try self.device.endCommandBuffer(command_buffer);

            try command_list_data.buffers.append(self.allocator, command_buffer);
            try command_list_data.types.append(self.allocator, scope.scope_type);
        }

        try self.submitted_command_lists[self.frame_index].append(self.allocator, command_list_data);
    }

    fn executeCommandScope(self: *const Device, command_buffer: vk.CommandBuffer, scope: *const CommandScope) !void {
        for (scope.commands.items) |command| {
            switch (command.args) {
                .bind_pipeline_args => |args| {
                    self.device.cmdBindPipeline(command_buffer, .graphics, args.pipeline.pipeline);
                },
                .bind_shader_resource_args => |args| {
                    const set: [1]vk.DescriptorSet = [_]vk.DescriptorSet { args.shader_resource.descriptor_set };

                    self.device.cmdBindDescriptorSets(
                        command_buffer,
                        .graphics,
                        args.pipeline.pipeline_layout,
                        args.set,
                        1,
                        &set,
                        0,
                        null
                    );
                },
                .set_viewport_args => |args| {
                    const viewport = [_]vk.Viewport {
                        .{
                            .x = args.position[0],
                            .y = args.position[1],
                            .width = args.size[0],
                            .height = args.size[1],
                            .min_depth = args.min_depth,
                            .max_depth = args.max_depth
                        }
                    };

                    self.device.cmdSetViewport(command_buffer, 0, 1, &viewport);
                },
                .set_scissor_args => |args| {
                    const scissor = [_]vk.Rect2D{
                        .{
                            .extent = .{ .width = @intFromFloat(args.max[0] - args.min[0]), .height = @intFromFloat(args.max[1] - args.min[1]) },
                            .offset = .{ .x = 0, .y = 0}
                        }
                    };

                    self.device.cmdSetScissor(command_buffer, 0, 1, &scissor);
                },
                .set_line_width_args => |args| {
                    self.device.cmdSetLineWidth(command_buffer, args.line_width);
                },
                .bind_vertex_buffers_args => |args| {
                    var buffers = try std.ArrayListUnmanaged(vk.Buffer).initCapacity(self.allocator, args.buffers.len);
                    var offsets = try std.ArrayListUnmanaged(vk.DeviceSize).initCapacity(self.allocator, args.buffers.len);

                    for (0..args.buffers.len) |i| {
                        buffers.appendAssumeCapacity(args.buffers[i].buffer);
                        offsets.appendAssumeCapacity(0);
                    }

                    self.device.cmdBindVertexBuffers(command_buffer, 0, @intCast(args.buffers.len), buffers.items.ptr, offsets.items.ptr);

                    offsets.deinit(self.allocator);
                    buffers.deinit(self.allocator);
                },
                .bind_index_buffer_args => |args| {
                    self.device.cmdBindIndexBuffer(command_buffer, args.buffer.buffer, 0, .uint32);
                },
                .draw_args => |args| {
                    self.device.cmdDraw(command_buffer, args.vertex_count, 1, args.vertex_offset, 0);
                },
                .draw_indexed_args => |args| {
                    self.device.cmdDrawIndexed(command_buffer, args.index_count, 1, args.index_offset, args.vertex_offset, 0);
                },
                .native_command => |native| {
                    native.record(self, @ptrFromInt(@intFromEnum(command_buffer)));
                }
            }
        }
    }

    pub fn beginSingleTimeCommands(self: *const Device) CommandList {
        var command_list = CommandList{
            .allocator = self.allocator,
            .is_single_time_commands = true,
        };
        command_list.begin();

        return command_list;
    }

    pub fn endSingleTimeCommands(self: *const Device, command_list: *CommandList) !void {
        if (!command_list.is_single_time_commands) {
            return error.NotSingleTimeCommands;
        }

        try command_list.end();

        const alloc_info = vk.CommandBufferAllocateInfo{
            .s_type = .command_buffer_allocate_info,
            .command_pool = self.command_pool,
            .command_buffer_count = 1,
            .level = .primary
        };

        var command_buffers = [_]vk.CommandBuffer { .null_handle };
        try self.device.allocateCommandBuffers(&alloc_info, &command_buffers);

        const command_buffer = command_buffers[0];

        const begin_info = vk.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info,
            .flags = .{ .one_time_submit_bit = true },
        };

        try self.device.beginCommandBuffer(command_buffer, &begin_info);

        for (command_list.scopes.items) |scope| {
            try self.executeCommandScope(command_buffer, &scope);
        }

        try self.device.endCommandBuffer(command_buffer);

        command_buffers[0] = command_buffer;

        const submit_info = [_]vk.SubmitInfo {
            .{
                .s_type = .submit_info,
                .command_buffer_count = 1,
                .p_command_buffers = &command_buffers
            }
        };

        try self.device.queueSubmit(self.graphics_queue, 1, &submit_info, .null_handle);
        try self.device.queueWaitIdle(self.graphics_queue);

        self.device.freeCommandBuffers(self.command_pool, 1, &command_buffers);
    
        self.destroyCommandList(command_list);
    }

    pub fn createSwapchain(self: *Device, swapchain_info: *const SwapchainInfo) !*Swapchain {
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

        self.swapchain = swapchain_obj;

        const semaphore_info = vk.SemaphoreCreateInfo{
            .s_type = .semaphore_create_info,
        };

        for (0..self.swapchain.?.swapchain_image_count) |_| {
            const semaphore = try self.device.createSemaphore(&semaphore_info, self.instance.vk_allocator);
            try self.render_finished_semaphores.append(self.allocator, semaphore);
        }

        return &self.swapchain.?;
    }

    pub fn destroySwapchain(self: *Device, swapchain: *Swapchain) void {
        self.device.deviceWaitIdle() catch {
            return;
        };

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
        self.device.deviceWaitIdle() catch {
            return;
        };

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

        const vertex_shader_stage_info = vk.PipelineShaderStageCreateInfo{
            .s_type = .pipeline_shader_stage_create_info,
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader_module,
            .p_name = "main"
        };

        const pixel_shader_stage_info = vk.PipelineShaderStageCreateInfo{
            .s_type = .pipeline_shader_stage_create_info,
            .stage = .{ .fragment_bit = true },
            .module = pixel_shader_module,
            .p_name = "main"
        };

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo { vertex_shader_stage_info, pixel_shader_stage_info };

        var dynamic_states = try std.ArrayListUnmanaged(vk.DynamicState).initCapacity(self.allocator, 2);
        defer dynamic_states.deinit(self.allocator);

        dynamic_states.appendAssumeCapacity(.viewport);
        dynamic_states.appendAssumeCapacity(.scissor);

        if (pipeline_info.primitive_topology == .line_list or pipeline_info.primitive_topology == .line_strip)
            try dynamic_states.append(self.allocator, .line_width);

        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .s_type = .pipeline_dynamic_state_create_info,
            .dynamic_state_count = @intCast(dynamic_states.items.len),
            .p_dynamic_states = dynamic_states.items.ptr
        };

        const vertex_input_layout = try pipeline_info.vertex_shader.reflectVertexInput(&self.allocator);
        const bytes0 = @as([]u8, std.mem.sliceAsBytes(vertex_input_layout.@"0"));
        const bytes1 = @as([]u8, std.mem.sliceAsBytes(vertex_input_layout.@"1"));
        defer self.allocator.free(bytes0);
        defer self.allocator.free(bytes1);

        var binding_descriptions = try self.allocator.alloc(vk.VertexInputBindingDescription, vertex_input_layout.@"0".len);
        defer self.allocator.free(binding_descriptions);
        var attribute_descriptions = try self.allocator.alloc(vk.VertexInputAttributeDescription, vertex_input_layout.@"1".len);
        defer self.allocator.free(attribute_descriptions);

        for (0..vertex_input_layout.@"0".len) |i| {
            binding_descriptions[i].binding = vertex_input_layout.@"0"[i].Binding;
            binding_descriptions[i].stride = vertex_input_layout.@"0"[i].Stride;
            binding_descriptions[i].input_rate = @enumFromInt(@as(i32, @intCast(vertex_input_layout.@"0"[i].InputRate)));
        }

        for (0..vertex_input_layout.@"1".len) |i| {
            attribute_descriptions[i].binding = vertex_input_layout.@"1"[i].Binding;
            attribute_descriptions[i].location = vertex_input_layout.@"1"[i].Location;
            attribute_descriptions[i].offset = vertex_input_layout.@"1"[i].Offset;
            attribute_descriptions[i].format = @enumFromInt(vertex_input_layout.@"1"[i].Format);
        }

        for (attribute_descriptions) |desc| {
            std.debug.print("binding = {}, format = {s}, location = {}, offset = {}\n", .{ desc.binding, @tagName(desc.format), desc.location, desc.offset });
        }

        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .s_type = .pipeline_vertex_input_state_create_info,
            .vertex_binding_description_count = @intCast(binding_descriptions.len),
            .p_vertex_binding_descriptions = binding_descriptions.ptr,
            .vertex_attribute_description_count = @intCast(attribute_descriptions.len),
            .p_vertex_attribute_descriptions = attribute_descriptions.ptr
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .s_type = .pipeline_input_assembly_state_create_info,
            .topology = convertPrimitiveTopology(pipeline_info.primitive_topology),
            .primitive_restart_enable = .false,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .s_type = .pipeline_viewport_state_create_info,
            .viewport_count = 1,
            .scissor_count = 1
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .s_type = .pipeline_rasterization_state_create_info,
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .line_width = 1.0,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .s_type = .pipeline_multisample_state_create_info,
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .true,
            .min_sample_shading = 0.2,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false
        };

        const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState {
            vk.PipelineColorBlendAttachmentState{
                .blend_enable = .true,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true }
            },
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .s_type = .pipeline_color_blend_state_create_info,
            .logic_op_enable = .false,
            .attachment_count = @intCast(color_blend_attachments.len),
            .p_attachments = &color_blend_attachments,
            .blend_constants = [_]f32 { 0.0, 0.0, 0.0, 0.0 },
            .logic_op = .clear
        };

        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .s_type = .pipeline_depth_stencil_state_create_info,
            .depth_test_enable = .true,
            .depth_write_enable = .true,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
            .stencil_test_enable = .false,
            .front = std.mem.zeroInit(vk.StencilOpState, .{}),
            .back = std.mem.zeroInit(vk.StencilOpState, .{})
        };

        const set_layouts = pipeline_info.shader_resource_layout.descriptor_set_layout.items;

        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .s_type = .pipeline_layout_create_info,
            .set_layout_count = @intCast(set_layouts.len),
            .p_set_layouts = set_layouts.ptr,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null
        };

        const pipeline_layout = try self.device.createPipelineLayout(&pipeline_layout_info, self.instance.vk_allocator);
        errdefer self.device.destroyPipelineLayout(pipeline_layout, self.instance.vk_allocator);

        const pipeline_create_info = vk.GraphicsPipelineCreateInfo{
            .s_type = .graphics_pipeline_create_info,
            .stage_count = @intCast(shader_stages.len),
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = &depth_stencil,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state,
            .layout = pipeline_layout,
            .render_pass = pipeline_info.render_pass.render_pass,
            .subpass = 0,
            .base_pipeline_index = 0,
        };

        const pipeline_create_infos = [_]vk.GraphicsPipelineCreateInfo{ pipeline_create_info };
        var pipelines: [1]vk.Pipeline = std.mem.zeroes([1]vk.Pipeline);

        _ = try self.device.createGraphicsPipelines(.null_handle, 1, &pipeline_create_infos, self.instance.vk_allocator, &pipelines);
        errdefer self.device.destroyPipeline(pipelines[0], self.instance.vk_allocator);

        const pipeline_obj = GraphicsPipeline{
            .allocator = self.allocator,
            .device = self,
            .pipeline_info = pipeline_info.*,
            .vertex_shader = vertex_shader_module,
            .pixel_shader = pixel_shader_module,
            .resource_layout = pipeline_info.shader_resource_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipelines[0]
        };

        return pipeline_obj;
    }

    pub fn createBuffer(self: *Device, buffer_type: BufferType, size: usize) !Buffer {
        var buffer = Buffer{
            .device = self,
            .buffer_type = buffer_type,
            .size = size,
        };

        try createBufferInternal(
            self.instance.instance,
            self.physical_device,
            self.device,
            self.instance.vk_allocator,
            size,
            getBufferUsage(buffer_type),
            getBufferMemoryProperties(buffer_type),
            &buffer.buffer,
            &buffer.memory
        );

        if (needsStagingBuffer(buffer_type)) {
            try createBufferInternal(
                self.instance.instance,
                self.physical_device,
                self.device,
                self.instance.vk_allocator,
                size,
                .{ .transfer_src_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
                &buffer.staging_buffer,
                &buffer.staging_memory
            );
        }

        return buffer;
    }

    pub fn createBufferWithData(self: *Device, buffer_type: BufferType, data: []const u8) !Buffer {
        var buffer = Buffer{
            .device = self,
            .buffer_type = buffer_type,
            .size = data.len,
        };

        try createBufferInternal(
            self.instance.instance,
            self.physical_device,
            self.device,
            self.instance.vk_allocator,
            data.len,
            getBufferUsage(buffer_type),
            getBufferMemoryProperties(buffer_type),
            &buffer.buffer,
            &buffer.memory
        );

        if (needsStagingBuffer(buffer_type)) {
            try createBufferInternal(
                self.instance.instance,
                self.physical_device,
                self.device,
                self.instance.vk_allocator,
                data.len,
                .{ .transfer_src_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
                &buffer.staging_buffer,
                &buffer.staging_memory
            );
        }

        try buffer.setData(data, 0);

        return buffer;
    }

    pub fn destroyBuffer(self: *const Device, buffer: *const Buffer) void {
        self.device.deviceWaitIdle() catch {
            return;
        };

        if (needsStagingBuffer(buffer.buffer_type)) {
            self.device.destroyBuffer(buffer.staging_buffer, self.instance.vk_allocator);
            self.device.freeMemory(buffer.staging_memory, self.instance.vk_allocator);
        }

        self.device.destroyBuffer(buffer.buffer, self.instance.vk_allocator);
        self.device.freeMemory(buffer.memory, self.instance.vk_allocator);
    }

    pub fn destroyGraphicsPipeline(self: *const Device, pipeline: *const GraphicsPipeline) void {
        self.device.deviceWaitIdle() catch {
            return;
        };

        self.device.destroyPipeline(pipeline.pipeline, self.instance.vk_allocator);
        self.device.destroyPipelineLayout(pipeline.pipeline_layout, self.instance.vk_allocator);
        self.device.destroyShaderModule(pipeline.pixel_shader, self.instance.vk_allocator);
        self.device.destroyShaderModule(pipeline.vertex_shader, self.instance.vk_allocator);
    }

    pub fn createCommandList(self: *const Device) CommandList {
        return .{
            .allocator = self.allocator,
        };
    }

    pub fn destroyCommandList(self: *const Device, command_list: *CommandList) void {
        self.device.deviceWaitIdle() catch {
            return;
        };

        for (0..command_list.scopes.items.len) |i| {
            var scope: *CommandScope = @constCast(&command_list.scopes.items[i]);
            for (scope.commands.items) |entry| {
                switch (entry.args) {
                    .native_command => |native| {
                        var n = native;
                        var allocator = self.allocator;
                        n.deinit(&allocator);
                    },
                    else => {}
                }
            }

            scope.commands.deinit(command_list.allocator);
        }

        command_list.scopes.deinit(command_list.allocator);
    }

    pub fn initShaderResourceLayout(self: *const Device, shader_resource_layout: *ShaderResourceLayout) !void {
        for (shader_resource_layout.sets) |set| {
            var bindings: std.ArrayList(vk.DescriptorSetLayoutBinding) = .{};
            defer bindings.deinit(self.allocator);

            for (set.resources) |resource| {
                const descriptor_binding = vk.DescriptorSetLayoutBinding{
                    .binding = resource.binding,
                    .descriptor_type = convertShaderResourceType(resource.resource_type),
                    .descriptor_count = resource.resource_array_count,
                    .stage_flags = convertShaderStage(resource.stage)
                };

                try bindings.append(self.allocator, descriptor_binding);
            }

            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .s_type = .descriptor_set_layout_create_info,
                .binding_count = @intCast(bindings.items.len),
                .p_bindings = bindings.items.ptr,
            };

            try shader_resource_layout.descriptor_set_layout.append(self.allocator, try self.device.createDescriptorSetLayout(&layout_info, self.instance.vk_allocator));
        }
    }

    pub fn deinitShaderResourceLayout(self: *const Device, shader_resource_layout: *ShaderResourceLayout) void {
        for (shader_resource_layout.descriptor_set_layout.items) |set_layout| {
            self.device.destroyDescriptorSetLayout(set_layout, self.instance.vk_allocator);
        }
        shader_resource_layout.descriptor_set_layout.deinit(self.allocator);
    }

    pub fn createShaderResource(self: *Device, set: u32, shader_resource_layout: *const ShaderResourceLayout) !ShaderResource {
        const set_layouts = [_]vk.DescriptorSetLayout{ shader_resource_layout.descriptor_set_layout.items[set] };

        const alloc_info = vk.DescriptorSetAllocateInfo{
            .s_type = .descriptor_set_allocate_info,
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &set_layouts
        };

        var sets = [_]vk.DescriptorSet{ .null_handle };

        try self.device.allocateDescriptorSets(&alloc_info, &sets);

        return .{
            .device = self,
            .layout = shader_resource_layout,
            .descriptor_set = sets[0]
        };
    }

    pub fn destroyShaderResource(self: *const Device, shader_resource: *const ShaderResource) void {
        _ = self;
        _ = shader_resource;
    }

    const vulkan_copy_buffer_native_command_vtable = NativeCommandVTable{
        .record = VulkanCopyBufferNativeCommand.record,
        .destroy = VulkanCopyBufferNativeCommand.destroy,
    };

    const VulkanCopyBufferNativeCommand = struct {
        src: vk.Buffer,
        dst: vk.Buffer,
        size: usize,
        src_offset: usize,
        dst_offset: usize,

        pub fn create(allocator: *std.mem.Allocator, src: vk.Buffer, dst: vk.Buffer, size: usize, src_offset: usize, dst_offset: usize) !NativeCommand {
            const cmd_size = @sizeOf(VulkanCopyBufferNativeCommand);
            const raw = try allocator.alloc(u8, cmd_size);

            const ptr = @as(*VulkanCopyBufferNativeCommand, @ptrCast(@alignCast(raw.ptr)));
            ptr.* = VulkanCopyBufferNativeCommand{
                .src = src,
                .dst = dst,
                .size = size,
                .src_offset = src_offset,
                .dst_offset = dst_offset,
            };

            return NativeCommand.init(&vulkan_copy_buffer_native_command_vtable, raw.ptr, raw.len);
        }

        pub fn record(device: *const Device, payload: ?[*]const u8, payload_size: usize, command_buffer: *anyopaque) void {
            const cmd = @as(*const VulkanCopyBufferNativeCommand, @ptrCast(@alignCast(payload)));
            const vk_cmd = @as(vk.CommandBuffer, @enumFromInt(@intFromPtr(command_buffer)));

            const copy = [_]vk.BufferCopy{
                .{
                    .src_offset = @intCast(cmd.src_offset),
                    .dst_offset = @intCast(cmd.dst_offset),
                    .size = @intCast(cmd.size)
                }
            };

            device.device.cmdCopyBuffer(vk_cmd, cmd.src, cmd.dst, 1, &copy);

            _ = payload_size;
        }

        pub fn destroy(payload: ?[*]u8, payload_size: usize, allocator: *std.mem.Allocator) void {
            if (payload) |p| {
                allocator.free(p[0..payload_size]);
            }
        }
    };

    pub fn nativeBufferCopy(self: *Device, src: vk.Buffer, dst: vk.Buffer, size: usize, src_offset: usize, dst_offset: usize) !NativeCommand {
        return try VulkanCopyBufferNativeCommand.create(
            &self.allocator,
            src,
            dst,
            size,
            src_offset,
            dst_offset
        );
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
        features.sampler_anisotropy == .true and
        features.sample_rate_shading == .true;
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

fn convertShaderStage(stage: ShaderStage) vk.ShaderStageFlags {
    switch (stage) {
        .vertex => return .{ .vertex_bit = true },
        .pixel => return .{ .fragment_bit = true },
        .compute => return .{ .compute_bit = true },
    }
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

fn convertPrimitiveTopology(topology: PrimitiveTopology) vk.PrimitiveTopology {
    switch (topology) {
        .triangle_list => return .triangle_list,
        .line_list => return .line_list,
        .line_strip => return .line_strip
    }
}

fn convertShaderResourceType(resource_type: ShaderResourceType) vk.DescriptorType {
    return switch (resource_type) {
        .constant_buffer => .uniform_buffer,
        .combined_image_sampler => .combined_image_sampler,
        .sampled_image => .sampled_image,
        .sampler => .sampler,
        .storage_buffer => .storage_buffer,
        .storage_image => .storage_image,
    };
}

fn getBufferUsage(buffer_type: BufferType) vk.BufferUsageFlags {
    var flags: vk.BufferUsageFlags = .{};

    if (@intFromEnum(buffer_type) & @intFromEnum(BufferType.vertex_buffer) != 0) {
        flags.vertex_buffer_bit = true;
    }
    if (@intFromEnum(buffer_type) & @intFromEnum(BufferType.index_buffer) != 0) {
        flags.index_buffer_bit = true;
        flags.transfer_dst_bit = true;
    }
    if (@intFromEnum(buffer_type) & @intFromEnum(BufferType.staging_buffer) != 0) {
        flags.transfer_src_bit = true;
        flags.transfer_dst_bit = true;
    }
    if (@intFromEnum(buffer_type) & @intFromEnum(BufferType.constant_buffer) != 0) {
        flags.uniform_buffer_bit = true;
    }
    if (@intFromEnum(buffer_type) & @intFromEnum(BufferType.storage_buffer) != 0) {
        flags.transfer_src_bit = true;
        flags.transfer_dst_bit = true;
        flags.storage_buffer_bit = true;
    }

    return flags;
}

pub fn needsStagingBuffer(buffer_type: BufferType) bool {
    return (@intFromEnum(buffer_type) & @intFromEnum(BufferType.index_buffer) != 0) or (@intFromEnum(buffer_type) & @intFromEnum(BufferType.storage_buffer) != 0);
}

fn getBufferMemoryProperties(buffer_type: BufferType) vk.MemoryPropertyFlags {
    var flags: vk.MemoryPropertyFlags = .{};

    if (needsStagingBuffer(buffer_type)) {
        flags.device_local_bit = true;
    } else {
        flags.host_visible_bit = true;
        flags.host_coherent_bit = true;
    }

    return flags;
}

fn createBufferInternal(instance: vk.InstanceProxy, physical_device: vk.PhysicalDevice, device: vk.DeviceProxy, allocator: ?*const vk.AllocationCallbacks, size: usize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, out_buffer: *vk.Buffer, out_memory: *vk.DeviceMemory) !void {
    const buffer_info = vk.BufferCreateInfo{
        .s_type = .buffer_create_info,
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive
    };

    out_buffer.* = try device.createBuffer(&buffer_info, allocator);

    const mem_requirements: vk.MemoryRequirements = device.getBufferMemoryRequirements(out_buffer.*);

    const alloc_info = vk.MemoryAllocateInfo{
        .s_type = .memory_allocate_info,
        .allocation_size = mem_requirements.size,
        .memory_type_index = try findMemoryType(instance, physical_device, mem_requirements.memory_type_bits, properties)
    };

    out_memory.* = try device.allocateMemory(&alloc_info, allocator);
    
    try device.bindBufferMemory(out_buffer.*, out_memory.*, 0);
}
