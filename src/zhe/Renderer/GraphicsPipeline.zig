const std = @import("std");
const vk = @import("vulkan");

const Device = @import("Device.zig").Device;
const Buffer = @import("Buffer.zig").Buffer;
const RenderPass = @import("RenderPass.zig").RenderPass;
const ShaderEntryPoint = @import("ShaderLibrary.zig").ShaderEntryPoint;
const ShaderStage = @import("ShaderLibrary.zig").ShaderStage;
const ShaderResourceType = @import("ShaderLibrary.zig").ShaderResourceType;
const ShaderResourceLayout = @import("ShaderResource.zig").ShaderResourceLayout;

const MaxFramesInFlight = @import("Instance.zig").MaxFramesInFlight;

pub const PrimitiveTopology = enum {
    triangle_list,
    line_list,
    line_strip
};

pub const PushConstantInfo = struct {
    size: usize,
    offset: usize,
    shader_type: ShaderStage
};

pub const GraphicsPipelineInfo = struct {
    vertex_shader: ShaderEntryPoint,
    pixel_shader: ShaderEntryPoint,
    primitive_topology: PrimitiveTopology,
    render_pass: *RenderPass,
    shader_resource_layout: ShaderResourceLayout,
};

pub const GraphicsPipeline = struct {

    allocator: std.mem.Allocator,
    device: *Device,

    pipeline_info: GraphicsPipelineInfo,

    vertex_shader: vk.ShaderModule,
    pixel_shader: vk.ShaderModule,

    resource_layout: ShaderResourceLayout,

    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

};
