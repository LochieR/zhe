const std = @import("std");

const GraphicsPipeline = @import("GraphicsPipeline.zig").GraphicsPipeline;
const RenderPass = @import("RenderPass.zig").RenderPass;
const Buffer = @import("Buffer.zig").Buffer;
const Device = @import("Device.zig").Device;
const ShaderResource = @import("ShaderResource.zig").ShaderResource;

pub const Vec2f = @Vector(2, f32);

pub const NativeCommandVTable = struct {
    record: *const fn (device: *const Device, payload: ?[*]const u8, payload_size: usize, command_buffer: *anyopaque) void,
    destroy: *const fn (payload: ?[*]u8, payload_size: usize, allocator: *std.mem.Allocator) void,
};

pub const NativeCommand = struct {
    vtable: ?*const NativeCommandVTable = null,
    payload: ?[*]u8 = null,
    payload_size: usize = 0,

    pub fn init(vtable: *const NativeCommandVTable, payload: [*]u8, payload_size: usize) NativeCommand {
        return NativeCommand{
            .vtable = vtable,
            .payload = payload,
            .payload_size = payload_size
        };
    }

    pub fn record(self: *const NativeCommand, device: *const Device, command_buffer: *anyopaque) void {
        if (self.vtable) |vtable| {
            vtable.record(device, self.payload, self.payload_size, command_buffer);
        }
    }

    pub fn deinit(self: *NativeCommand, allocator: *std.mem.Allocator) void {
        if (self.vtable) |vtable| {
            vtable.destroy(self.payload, self.payload_size, allocator);
            self.vtable = null;
            self.payload = null;
            self.payload_size = 0;
        }
    }
};

const CommandEntry = struct {
    const BindPipelineArgs = struct {
        pipeline: *const GraphicsPipeline,
    };

    const BindShaderResourceArgs = struct {
        pipeline: *const GraphicsPipeline,
        set: u32,
        shader_resource: *const ShaderResource,
    };

    const SetViewportArgs = struct {
        pipeline: *const GraphicsPipeline,
        position: Vec2f,
        size: Vec2f,
        min_depth: f32,
        max_depth: f32
    };

    const SetScissorArgs = struct {
        pipeline: *const GraphicsPipeline,
        min: Vec2f,
        max: Vec2f
    };

    const SetLineWidthArgs = struct {
        pipeline: *const GraphicsPipeline,
        line_width: f32
    };

    const BindVertexBuffersArgs = struct {
        buffers: []*const Buffer,
    };

    const BindIndexBufferArgs = struct {
        buffer: *const Buffer
    };

    const DrawArgs = struct {
        vertex_count: u32,
        vertex_offset: u32
    };

    const DrawIndexedArgs = struct {
        index_count: u32,
        vertex_offset: i32,
        index_offset: u32
    };

    const CommandEntryArgs = union(enum) {
        bind_pipeline_args: BindPipelineArgs,
        bind_shader_resource_args: BindShaderResourceArgs,
        set_viewport_args: SetViewportArgs,
        set_scissor_args: SetScissorArgs,
        set_line_width_args: SetLineWidthArgs,
        bind_vertex_buffers_args: BindVertexBuffersArgs,
        bind_index_buffer_args: BindIndexBufferArgs,
        draw_args: DrawArgs,
        draw_indexed_args: DrawIndexedArgs,
        native_command: NativeCommand,
    };

    args: CommandEntryArgs,

};

pub const CommandScopeType = enum {
    general, render_pass
};

pub const CommandScope = struct {

    scope_type: CommandScopeType,

    current_render_pass: ?*RenderPass = null,
    commands: std.ArrayListUnmanaged(CommandEntry) = .{},

};

pub const CommandListError = error {
    NoPipelineBound,
};

pub const CommandList = struct {

    allocator: std.mem.Allocator,

    is_recording: bool = false,
    is_single_time_commands: bool = false,
    scopes: std.ArrayList(CommandScope) = .{},
    current_scope: ?CommandScope = null,

    current_graphics_pipeline: ?*const GraphicsPipeline = null,

    pub fn init(allocator: std.mem.Allocator) !CommandList {
        var command_list = CommandList{ .allocator = allocator };
        command_list.is_recording = false;
        return command_list;
    }

    pub fn begin(self: *CommandList) void {
        self.current_scope = CommandScope{
            .commands = .{},
            .current_render_pass = null,
            .scope_type = .general
        };

        self.is_recording = true;

        for (0..self.scopes.items.len) |i| {
            var scope: *CommandScope = @constCast(&self.scopes.items[i]);
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

            scope.commands.deinit(self.allocator);
        }

        self.scopes.clearRetainingCapacity();
    }

    pub fn end(self: *CommandList) !void {
        self.is_recording = false;
        self.current_graphics_pipeline = null;
        try self.scopes.append(self.allocator, self.current_scope orelse .{ .scope_type = .general });
        self.current_scope = null;
    }

    pub fn beginRenderPass(self: *CommandList, render_pass: *RenderPass) !void {
        try self.scopes.append(self.allocator, self.current_scope orelse .{ .scope_type = .general });
        self.current_scope = CommandScope{
            .commands = .{},
            .scope_type = .render_pass,
            .current_render_pass = render_pass
        };
    }

    pub fn endRenderPass(self: *CommandList) !void {
        try self.scopes.append(self.allocator, self.current_scope orelse .{ .scope_type = .general });
        self.current_scope = CommandScope{ .commands = .{}, .scope_type = .general, .current_render_pass = null };
    }

    pub fn bindPipeline(self: *CommandList, pipeline: *const GraphicsPipeline) !void {
        const entry = CommandEntry{
            .args = .{ .bind_pipeline_args = .{ .pipeline = pipeline } }
        };

        self.current_graphics_pipeline = pipeline;
        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn bindShaderResource(self: *CommandList, set: u32, shader_resource: *const ShaderResource) !void {
        if (self.current_graphics_pipeline == null) {
            return error.NoPipelineBound;
        }

        const entry = CommandEntry{
            .args = .{
                .bind_shader_resource_args = .{
                    .pipeline = self.current_graphics_pipeline.?,
                    .set = set,
                    .shader_resource = shader_resource
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn setViewport(self: *CommandList, position: Vec2f, size: Vec2f, min_depth: f32, max_depth: f32) !void {
        if (self.current_graphics_pipeline == null) {
            return error.NoPipelineBound;
        }

        const entry = CommandEntry{
            .args = .{
                .set_viewport_args = .{
                    .pipeline = self.current_graphics_pipeline.?,
                    .position = position,
                    .size = size,
                    .min_depth = min_depth,
                    .max_depth = max_depth
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn setScissor(self: *CommandList, min: Vec2f, max: Vec2f) !void {
        if (self.current_graphics_pipeline == null) {
            return error.NoPipelineBound;
        }

        const entry = CommandEntry{
            .args = .{
                .set_scissor_args = .{
                    .pipeline = self.current_graphics_pipeline.?,
                    .min = min,
                    .max = max,
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn setLineWidth(self: *CommandList, line_width: f32) !void {
        if (self.current_graphics_pipeline == null) {
            return error.NoPipelineBound;
        }

        const entry = CommandEntry{
            .args = .{
                .set_line_width_args = .{
                    .pipeline = self.current_graphics_pipeline.?,
                    .line_width = line_width,
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn bindVertexBuffers(self: *CommandList, buffers: []*const Buffer) !void {
        const entry = CommandEntry{
            .args = .{
                .bind_vertex_buffers_args = .{
                    .buffers = buffers,
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn bindIndexBuffer(self: *CommandList, buffer: *const Buffer) !void {
        const entry = CommandEntry{
            .args = .{
                .bind_index_buffer_args = .{
                    .buffer = buffer,
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn draw(self: *CommandList, vertex_count: u32, vertex_offset: u32) !void {
        const entry = CommandEntry{
            .args = .{
                .draw_args = .{
                    .vertex_count = vertex_count,
                    .vertex_offset = vertex_offset,
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn drawIndexed(self: *CommandList, index_count: u32, vertex_offset: i32, index_offset: u32) !void {
        const entry = CommandEntry{
            .args = .{
                .draw_indexed_args = .{
                    .index_count = index_count,
                    .vertex_offset = vertex_offset,
                    .index_offset = index_offset,
                }
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

    pub fn submitNativeCommand(self: *CommandList, native_command: *const NativeCommand) !void {
        const entry = CommandEntry{
            .args = .{
                .native_command = native_command.*
            }
        };

        try self.current_scope.?.commands.append(self.allocator, entry);
    }

};

