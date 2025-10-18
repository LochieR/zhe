const std = @import("std");
const zhe = @import("zhe");
const vk = @import("vulkan");
const builtin = @import("builtin");

const windows = @cImport({
    @cInclude("windows.h");
    @cInclude("dwmapi.h");
});

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
    @cInclude("GLFW/glfw3native.h");
});

const ZheError = error{
    GlfwInitFailed,
    NoVulkan,
    FailedToCreateWindow
};

const ShaderContext = struct {
    shader_library: zhe.ShaderLibrary,
    basic_module: zhe.ShaderModule,
    basic_vertex_entry_point: zhe.ShaderEntryPoint,
    basic_pixel_entry_point: zhe.ShaderEntryPoint,
};

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    mutex: *std.Thread.Mutex,
    output: *?ShaderContext,
    result: *?anyerror,
};

const Vertex = struct {
    position: @Vector(4, f32),
    color: @Vector(4, f32),
    tex_coord: @Vector(4, f32)
};

const f4x4 = [4]@Vector(4, f32);

const CameraData = struct {
    view_projection: f4x4
};

fn createErrorUnion(err: anyerror) !void {
    return err;
}

pub fn main() !void {
    if (c.glfwInit() != c.GLFW_TRUE) {
        std.log.err("failed to initialize GLFW", .{});
        return error.GlfwInitFailed;
    }
    defer c.glfwTerminate();

    if (c.glfwVulkanSupported() == c.GLFW_FALSE) {
        std.log.err("vulkan is not supported", .{});
        return error.NoVulkan;
    }

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
    const window = c.glfwCreateWindow(
        1280,
        720,
        "zheditor",
        null,
        null
    ) orelse return error.FailedToCreateWindow;
    defer c.glfwDestroyWindow(window);

    //const margins = windows.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 1, .cyBottomHeight = 0 };
    //const hwnd = c.glfwGetWin32Window(window);
    //_ = windows.DwmExtendFrameIntoClientArea(@ptrCast(hwnd), &margins);
    //_ = windows.SetWindowLongA(@ptrCast(hwnd), windows.GWL_STYLE, windows.WS_OVERLAPPEDWINDOW & ~windows.WS_CAPTION);
    //_ = windows.SetWindowLongA(@ptrCast(hwnd), windows.GWL_EXSTYLE, windows.WS_EX_APPWINDOW | windows.WS_EX_WINDOWEDGE);

    var allocator: std.mem.Allocator = undefined;
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;

    if (builtin.mode == .Debug) {
        gpa = std.heap.GeneralPurposeAllocator(.{}){};
        allocator = gpa.allocator();
    } else {
        allocator = std.heap.c_allocator;
    }

    defer {
        if (builtin.mode == .Debug) {
            _ = gpa.deinit();
        }
    }

    // begin shader compilation
    var shader_context: ?ShaderContext = null;
    var mutex = std.Thread.Mutex{};
    var result: ?anyerror = null;

    var worker_args = WorkerArgs{
        .allocator = allocator,
        .mutex = &mutex,
        .output = &shader_context,
        .result = &result
    };

    const worker = try std.Thread.spawn(.{}, compileShaders, .{ &worker_args });

    const instance_info = zhe.InstanceInfo{
        .app_name = "zheditor",
        .window = @ptrCast(window),
        .allocator = allocator
    };
    var instance = try zhe.Instance.init(&instance_info);
    defer instance.deinit();

    var device = try instance.createDevice();
    defer instance.destroyDevice(&device);

    const swapchain_info = zhe.SwapchainInfo{
        .attachments = &[_]zhe.AttachmentFormat{ .swapchain_color_default, .swapchain_depth_default },
        .present_mode = .mailbox_or_fifo
    };

    const swapchain = try device.createSwapchain(&swapchain_info);
    defer device.destroySwapchain(swapchain);

    const color_attachment = zhe.AttachmentInfo{
        .format = .swapchain_color_default,
        .previous_layout = .undefined,
        .layout = .present,
        .samples = 1,
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care
    };

    const depth_attachment = zhe.AttachmentInfo{
        .format = .swapchain_depth_default,
        .previous_layout = .undefined,
        .layout = .depth,
        .samples = 1,
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care
    };

    const attachments = [2]zhe.AttachmentInfo{ color_attachment, depth_attachment };

    const render_pass_info = zhe.RenderPassInfo{
        .attachments = &attachments,
    };

    var render_pass = try device.createRenderPass(swapchain, &render_pass_info);
    defer device.destroyRenderPass(&render_pass);

    worker.join();
    mutex.lock();
    
    if (result) |res| {
        try createErrorUnion(res);
    }
    const shader = shader_context orelse {
        mutex.unlock();
        std.debug.print("compile failed", .{});
        return;
    };

    defer shader.shader_library.deinit();

    var shader_resource_layout = zhe.ShaderResourceLayout{
        .sets = &[_]zhe.ShaderResourceSet {
            zhe.ShaderResourceSet{
                .resources = &[_]zhe.ResourceLayoutItem{
                    .{
                        .binding = 0,
                        .resource_type = .constant_buffer,
                        .resource_array_count = 1,
                        .stage = .vertex
                    }
                }
            }
        },
    };

    try device.initShaderResourceLayout(&shader_resource_layout);
    defer device.deinitShaderResourceLayout(&shader_resource_layout);

    const graphics_pipeline_info = zhe.GraphicsPipelineInfo{
        .vertex_shader = shader.basic_vertex_entry_point,
        .pixel_shader = shader.basic_pixel_entry_point,
        .primitive_topology = .triangle_list,
        .render_pass = &render_pass,
        .shader_resource_layout = shader_resource_layout
    };

    const graphics_pipeline = try device.createGraphicsPipeline(&graphics_pipeline_info);
    defer device.destroyGraphicsPipeline(&graphics_pipeline);

    const indices = [_]u32 {
        0, 1, 2, 2, 3, 0
    };
    const index_buffer = try device.createBufferWithData(.index_buffer, std.mem.sliceAsBytes(indices[0..indices.len]));
    defer device.destroyBuffer(&index_buffer);

    const vertices = [_]Vertex {
        .{
            .position = @Vector(4, f32){ -0.5, -0.5, 0.0, 1.0 },
            .color = @Vector(4, f32){ 0.6, 0.3, 0.8, 1.0 },
            .tex_coord = @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 },
        },
        .{
            .position = @Vector(4, f32){ 0.5, -0.5, 0.0, 1.0 },
            .color = @Vector(4, f32){ 0.4, 0.1, 0.6, 1.0 },
            .tex_coord = @Vector(4, f32){ 1.0, 0.0, 0.0, 0.0 },
        },
        .{
            .position = @Vector(4, f32){ 0.5, 0.5, 0.0, 1.0 },
            .color = @Vector(4, f32){ 0.1, 0.7, 0.5, 1.0 },
            .tex_coord = @Vector(4, f32){ 1.0, 1.0, 0.0, 0.0 },
        },
        .{
            .position = @Vector(4, f32){ -0.5, 0.5, 0.0, 1.0 },
            .color = @Vector(4, f32){ 0.8, 0.3, 0.6, 1.0 },
            .tex_coord = @Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 },
        }
    };

    var vertex_buffer = try device.createBufferWithData(.vertex_buffer, std.mem.sliceAsBytes(vertices[0..vertices.len]));
    defer device.destroyBuffer(&vertex_buffer);

    var vertex_buffers = try std.ArrayList(*const zhe.Buffer).initCapacity(allocator, 1);
    defer vertex_buffers.deinit(allocator);
    vertex_buffers.appendAssumeCapacity(&vertex_buffer);

    var command_list = device.createCommandList();
    defer device.destroyCommandList(&command_list);

    const aspect = @as(f32, @floatFromInt(swapchain.extent.width)) / @as(f32, @floatFromInt(swapchain.extent.height));

    var constant_buffer = try device.createBuffer(.constant_buffer, @sizeOf(CameraData));
    defer device.destroyBuffer(&constant_buffer);

    const camera_data = CameraData{
        .view_projection = ortho(-aspect, aspect, -1.0, 1.0, 0.0, 1.0)
    };
    try constant_buffer.setData(std.mem.asBytes(&camera_data), 0);

    const constant_buffer_resource = try device.createShaderResource(0, &shader_resource_layout);
    constant_buffer_resource.update(&constant_buffer, 0, 0);

    c.glfwShowWindow(window);
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        try device.beginFrame();

        command_list.begin();

        try command_list.beginRenderPass(&render_pass);
        try command_list.bindPipeline(&graphics_pipeline);
        try command_list.bindShaderResource(0, &constant_buffer_resource);
        try command_list.setViewport(@Vector(2, f32){ 0.0, 0.0 }, @Vector(2, f32){ @floatFromInt(swapchain.extent.width), @floatFromInt(swapchain.extent.height) }, 0.0, 1.0);
        try command_list.setScissor(@Vector(2, f32){ 0.0, 0.0 }, @Vector(2, f32){ @floatFromInt(swapchain.extent.width), @floatFromInt(swapchain.extent.height) });
        try command_list.bindVertexBuffers(vertex_buffers.items);
        try command_list.bindIndexBuffer(&index_buffer);

        try command_list.drawIndexed(6, 0, 0);

        try command_list.endRenderPass();

        try command_list.end();
        try device.submitCommandList(&command_list);

        try device.endFrame();
        c.glfwPollEvents();
    }
}

fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) f4x4 {
    const rl = right - left;
    const tb = top - bottom;
    const fn_ = far - near;

    return .{
        .{ 2.0 / rl, 0.0, 0.0, 0.0 },
        .{ 0.0, 2.0 / tb, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 / fn_, 0.0 },
        .{ 
            -(right + left) / rl,
            -(top + bottom) / tb,
            -near / fn_,
            1.0
        }
    };
}

fn compileShaders(args: *WorkerArgs) void {
    const shader_library = zhe.ShaderLibrary.init(args.allocator) catch |err| {
        args.mutex.lock();
        args.output.* = null;
        args.result.* = err;
        args.mutex.unlock();
        return;
    };

    const vertex_entry_point_info = zhe.ShaderEntryPointInfo{
        .name = "vertexMain",
        .per_vertex_struct_name = "PerVertexInput",
    };

    const pixel_entry_point_info = zhe.ShaderEntryPointInfo{
        .name = "pixelMain",
    };

    const basic_module = shader_library.loadModule("basic") catch |err| {
        args.mutex.lock();
        args.output.* = null;
        args.result.* = err;
        args.mutex.unlock();
        return;
    };
    const basic_vertex_main = basic_module.loadEntryPoint(vertex_entry_point_info) catch |err| {
        args.mutex.lock();
        args.output.* = null;
        args.result.* = err;
        args.mutex.unlock();
        return;
    };
    const basic_pixel_main = basic_module.loadEntryPoint(pixel_entry_point_info) catch |err| {
        args.mutex.lock();
        args.output.* = null;
        args.result.* = err;
        args.mutex.unlock();
        return;
    };

    const context = ShaderContext{
        .shader_library = shader_library,
        .basic_module = basic_module,
        .basic_vertex_entry_point = basic_vertex_main,
        .basic_pixel_entry_point = basic_pixel_main
    };

    args.mutex.lock();
    args.output.* = context;
    args.result.* = null;
    args.mutex.unlock();
}

const LoggingAllocator = struct {
    const Self = @This();

    base_allocator: std.mem.Allocator,

    pub fn init(base_allocator: std.mem.Allocator) Self {
        return Self{
            .baseAllocator = base_allocator
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .resize = resize,
                .remap = remap
            }
        };
    }

    fn alloc(context: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        const result = self.baseAllocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |_| {
            std.debug.print("[ALLOC] {} bytes\n", .{len});
        } else {
            std.debug.print("[ALLOC] failed {} bytes\n", .{len});
        }

        return result;
    }

    fn resize(context: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(context));

        std.debug.print("[RESIZE] {} -> {} bytes\n", .{buf.len, new_len});

        return self.base_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(context: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(context));

        std.debug.print("[FREE] {} bytes\n", .{buf.len});

        self.base_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));

        const result = self.base_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (result) |_| {
            std.debug.print("[REMAP] {} -> {}\n", .{memory.len, new_len});
        } else {
            std.debug.print("[REMAP] failed {} -> {}\n", .{memory.len, new_len});
        }

        return result;
    }
};
