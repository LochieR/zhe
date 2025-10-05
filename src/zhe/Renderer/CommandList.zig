const std = @import("std");
const vk = @import("vulkan");

const CommandType = enum {
    beginRenderPass, endRenderPass,
    bindPipeline, pushConstants, bindDescriptorSet, setViewport, setScissor, setLineWidth,
    bindVertexBuffers, bindIndexBuffer,
    clearImage,
    draw, drawIndexed, dispatch,
};

const CommandEntry = struct {
    const BindPipelineArgs = struct {
        isGraphics: bool,
        pipeline: *anyopaque
    };

    const PushConstantArgs = struct {
        isGraphics: bool,
        pipeline: *anyopaque,
        
    };

    const CommandEntryArgs = union {

    };


};

const CommandScopeType = enum {
    general, renderPass
};

const CommandScope = struct {

    scopeType: CommandScopeType,

    currentRenderPass: *anyopaque

};

const CommandList = struct {

    isRecording: bool,


};

