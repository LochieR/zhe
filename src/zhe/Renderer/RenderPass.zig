const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw.zig");

const Device = @import("Device.zig").Device;
const Swapchain = @import("Swapchain.zig").Swapchain;
const AttachmentFormat = @import("Swapchain.zig").AttachmentFormat;

const convertFormat = @import("Swapchain.zig").convertFormat;

pub const LoadOperation = enum(i32) {
    load = 0,
    clear = 1,
    dont_care = 2
};

pub const StoreOperation = enum(i32) {
    store = 0,
    dont_care = 1
};

pub const AttachmentLayout = enum {
    undefined,
    general,
    shader_read_only,
    present,
    color,
    depth,
    transfer_src,
    transfer_dst,
};

pub const AttachmentInfo = struct {
    format: AttachmentFormat,
    previous_layout: AttachmentLayout,
    layout: AttachmentLayout,
    samples: u16,
    load_op: LoadOperation,
    store_op: StoreOperation,
    stencil_load_op: LoadOperation,
    stencil_store_op: StoreOperation,
};

pub const RenderPassInfo = struct {
    attachments: []const AttachmentInfo
};

pub const RenderPassError = error {
    SwapchainAttachmentMissing
};

pub const RenderPass = struct {

    allocator: std.mem.Allocator,
    device: *Device,
    
    swapchain: *Swapchain,
    pass_info: RenderPassInfo,

    render_pass: vk.RenderPass,
    framebuffers: std.array_list.Managed(vk.Framebuffer),
    attachment_indices: std.array_list.Managed(u32),

    pub fn recreate(self: *RenderPass) !void {
        self.dispose();
        
        const attachments = try self.createAttachmentDescriptions();
        defer attachments.deinit();

        const refs = try self.createAttachmentRefs();
        defer refs.deinit();

        const color_refs = try getColorRefs(self.allocator, refs.items);
        defer color_refs.deinit();

        const depth_ref = getDepthAttachmentRef(refs.items);

        const subpass = vk.SubpassDescription{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = @intCast(color_refs.items.len),
            .p_color_attachments = color_refs.items.ptr,
            .p_depth_stencil_attachment = depth_ref
        };

        var dependency = vk.SubpassDependency{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true }
        };

        if (depth_ref) |_| {
            dependency.src_stage_mask.early_fragment_tests_bit = true;
            dependency.dst_stage_mask.early_fragment_tests_bit = true;
            dependency.dst_access_mask.depth_stencil_attachment_write_bit = true;
        }

        const subpasses = [_]vk.SubpassDescription{ subpass };
        const dependencies = [_]vk.SubpassDependency{ dependency };

        const render_pass_info = vk.RenderPassCreateInfo{
            .s_type = .render_pass_create_info,
            .attachment_count = @intCast(attachments.items.len),
            .p_attachments = attachments.items.ptr,
            .subpass_count = 1,
            .p_subpasses = &subpasses,
            .dependency_count = 1,
            .p_dependencies = &dependencies
        };

        self.render_pass = try self.device.device.createRenderPass(&render_pass_info, self.device.instance.vk_allocator);
        self.attachment_indices.clearAndFree();

        // if swapchain
        for (self.pass_info.attachments) |rp_attachment| {
            var found = false;
            for (0..self.swapchain.swapchain_info.attachments.len) |i| {
                if (self.swapchain.swapchain_info.attachments[i] == rp_attachment.format) {
                    try self.attachment_indices.append(@intCast(i));
                    found = true;
                    break;
                }
            }

            if (!found) {
                return error.SwapchainAttachmentMissing;
            }
        }

        try self.recreateFramebuffers();
    }

    fn recreateFramebuffers(self: *RenderPass) !void {
        for (self.framebuffers.items) |framebuffer| {
            self.device.device.destroyFramebuffer(framebuffer, self.device.instance.vk_allocator);
        }

        // if swapchain
        try self.framebuffers.resize(self.swapchain.swapchain_image_count);

        for (0..self.swapchain.swapchain_image_count) |i| {
            const attachments = try self.swapchain.getAttachmentViewsWithIndices(&self.allocator, self.attachment_indices.items[0..self.attachment_indices.items.len], @intCast(i));
            defer attachments.deinit();

            const framebuffer_info = vk.FramebufferCreateInfo{
                .s_type = .framebuffer_create_info,
                .render_pass = self.render_pass,
                .attachment_count = @intCast(attachments.items.len),
                .p_attachments = attachments.items.ptr,
                .width = self.swapchain.extent.width,
                .height = self.swapchain.extent.height,
                .layers = 1
            };

            self.framebuffers.items[i] = try self.device.device.createFramebuffer(&framebuffer_info, self.device.instance.vk_allocator);
        }
    }

    pub fn dispose(self: *RenderPass) void {
        for (self.framebuffers.items) |framebuffer| {
            self.device.device.destroyFramebuffer(framebuffer, self.device.instance.vk_allocator);
        }
        self.framebuffers.deinit();
        self.attachment_indices.deinit();

        self.device.device.destroyRenderPass(self.render_pass, self.device.instance.vk_allocator);
    }

    fn createAttachmentDescriptions(self: *RenderPass) !std.array_list.Managed(vk.AttachmentDescription) {
        var result = std.array_list.Managed(vk.AttachmentDescription).init(self.allocator);

        for (self.pass_info.attachments) |attachment| {
            var desc = vk.AttachmentDescription{
                .format = .undefined,
                .samples = getSampleCountFlags(attachment.samples),
                .load_op = @enumFromInt(@intFromEnum(attachment.load_op)),
                .store_op = @enumFromInt(@intFromEnum(attachment.store_op)),
                .stencil_load_op = @enumFromInt(@intFromEnum(attachment.stencil_load_op)),
                .stencil_store_op = @enumFromInt(@intFromEnum(attachment.stencil_store_op)),
                .initial_layout = convertImageLayout(attachment.previous_layout),
                .final_layout = convertImageLayout(attachment.layout),
            };

            if (attachment.format == .swapchain_color_default) {
                desc.format = self.swapchain.swapchain_image_format;
            } else if (attachment.format == .swapchain_depth_default) {
                desc.format = try self.swapchain.getDefaultDepthAttachmentFormat();
            } else {
                desc.format = convertFormat(attachment.format);
            }

            try result.append(desc);
        }

        return result;
    }

    fn createAttachmentRefs(self: *RenderPass) !std.array_list.Managed(vk.AttachmentReference) {
        var result = std.array_list.Managed(vk.AttachmentReference).init(self.allocator);

        for (0..self.pass_info.attachments.len) |i| {
            const ref = vk.AttachmentReference{
                .attachment = @intCast(i),
                .layout = if (self.pass_info.attachments[i].format != .d32_sfloat and self.pass_info.attachments[i].format != .swapchain_depth_default)
                    .color_attachment_optimal
                else
                    .depth_stencil_attachment_optimal
            };

            try result.append(ref);
        }

        return result;
    }

    fn getColorRefs(allocator: std.mem.Allocator, refs: []vk.AttachmentReference) !std.array_list.Managed(vk.AttachmentReference) {
        var result = std.array_list.Managed(vk.AttachmentReference).init(allocator);

        for (refs) |ref| {
            if (ref.layout == .color_attachment_optimal) {
                try result.append(ref);
            }
        }

        return result;
    }

    fn getDepthAttachmentRef(refs: []vk.AttachmentReference) ?*const vk.AttachmentReference {
        for (refs) |ref| {
            if (ref.layout == .depth_attachment_optimal or ref.layout == .depth_stencil_attachment_optimal) {
                return &ref;
            }
        }

        return null;
    }

};

pub fn getSampleCountFlags(samples: u16) vk.SampleCountFlags {
    if (samples == 1) {
        return vk.SampleCountFlags{ .@"1_bit" = true };
    } else if (samples == 2) {
        return vk.SampleCountFlags{ .@"2_bit" = true };
    } else if (samples == 4) {
        return vk.SampleCountFlags{ .@"4_bit" = true };
    } else if (samples == 8) {
        return vk.SampleCountFlags{ .@"8_bit" = true };
    } else if (samples == 16) {
        return vk.SampleCountFlags{ .@"16_bit" = true };
    } else if (samples == 32) {
        return vk.SampleCountFlags{ .@"32_bit" = true };
    } else if (samples == 64) {
        return vk.SampleCountFlags{ .@"64_bit" = true };
    } else {
        return vk.SampleCountFlags{};
    }
}

pub fn convertImageLayout(layout: AttachmentLayout) vk.ImageLayout {
    return switch (layout) {
        .undefined => .undefined,
        .general => .general,
        .shader_read_only => .shader_read_only_optimal,
        .present => .present_src_khr,
        .color => .color_attachment_optimal,
        .depth => .depth_stencil_attachment_optimal,
        .transfer_src => .transfer_src_optimal,
        .transfer_dst => .transfer_dst_optimal,
    };
}
