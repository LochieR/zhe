const std = @import("std");
const zhe = @import("zhe");
const vk = @import("vulkan");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
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

    var swapchain = try device.createSwapchain(&swapchain_info);
    defer device.destroySwapchain(&swapchain);

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

    var render_pass = try device.createRenderPass(&swapchain, &render_pass_info);
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

    const graphics_pipeline_info = zhe.GraphicsPipelineInfo{
        .vertex_shader = shader.basic_vertex_entry_point,
        .pixel_shader = shader.basic_pixel_entry_point,
        .primitive_topology = .triangle_list,
        .render_pass = &render_pass
    };

    const graphics_pipeline = try device.createGraphicsPipeline(&graphics_pipeline_info);
    defer device.destroyGraphicsPipeline(&graphics_pipeline);

    c.glfwShowWindow(window);
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        c.glfwPollEvents();
    }
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
        .per_vertex_struct_name = "PerVertexInput"
    };

    const pixel_resources = [_]zhe.ShaderResource {
        zhe.ShaderResource{
            .binding = 0,
            .resource_type = .texture,
            .resource_count = 1
        },
        zhe.ShaderResource{
            .binding = 1,
            .resource_type = .sampler_state,
            .resource_count = 1
        }
    };

    const pixel_entry_point_info = zhe.ShaderEntryPointInfo{
        .name = "pixelMain",
        .shader_resources = pixel_resources[0..]
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
