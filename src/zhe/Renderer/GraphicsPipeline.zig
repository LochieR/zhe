const std = @import("std");
const vk = @import("vulkan");

const Device = @import("Device.zig").Device;
const RenderPass = @import("RenderPass.zig").RenderPass;
const ShaderEntryPoint = @import("ShaderLibrary.zig").ShaderEntryPoint;

const MaxFramesInFlight = @import("Instance.zig").MaxFramesInFlight;

pub const PrimitiveTopology = enum {
    triangle_list,
    line_list,
    line_strip
};

pub const ShaderType = enum {
    vertex,
    pixel
};

pub const PushConstantInfo = struct {
    size: usize,
    offset: usize,
    shader_type: ShaderType
};

pub const ShaderResourceType = enum {
    uniform_buffer,
    combined_image_sampler,
    sampled_image,
    sampler,
    storage_buffer,
    storage_image
};

pub const ShaderResourceInfo = struct {
    resource_type: ShaderResourceType,
    set: u32,
    binding: u32,
    shader: ShaderType,
    resource_count: u32 = 1
};

pub const GraphicsPipelineInfo = struct {
    vertex_shader: ShaderEntryPoint,
    pixel_shader: ShaderEntryPoint,
    primitive_topology: PrimitiveTopology,
    render_pass: *RenderPass
};

pub const GraphicsPipeline = struct {

    allocator: std.mem.Allocator,
    device: *Device,

    pipeline_info: GraphicsPipelineInfo,

    vertex_shader: vk.ShaderModule,
    pixel_shader: vk.ShaderModule,
    set_layout: vk.DescriptorSetLayout,

    descriptor_sets: [MaxFramesInFlight]vk.DescriptorSet,

    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    
};
