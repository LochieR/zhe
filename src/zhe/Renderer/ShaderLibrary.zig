const std = @import("std");

const slang = @cImport({
    @cInclude("slang/slang_bridge.h");
});

pub const SlangResult = error {
    Fail,
    NotImplemented,
    NoInterface,
    Abort,
    InvalidHandle,
    InvalidArg,
    OutOfMemory,
    BufferTooSmall,
    Uninitialized,
    Pending,
    CannotOpen,
    NotFound,
    InternalFail,
    NotAvailable,
    TimeOut
};

fn createSlangResult(result: i32) !void {
    if (result == 0) {
        return;
    } else if (result == -2147467259) {
        return error.Fail;
    } else if (result == -2147467263) {
        return error.NotImplemented;
    } else if (result == -2147467262) {
        return error.NoInterface;
    } else if (result == -2147467260) {
        return error.Abort;
    } else if (result == -2147024890) {
        return error.InvalidHandle;
    } else if (result == -2147024809) {
        return error.InvalidArg;
    } else if (result == -2147024882) {
        return error.OutOfMemory;
    } else if (result == -2113929215) {
        return error.BufferTooSmall;
    } else if (result == -2113929214) {
        return error.Uninitialized;
    } else if (result == -2113929213) {
        return error.Pending;
    } else if (result == -2113929212) {
        return error.CannotOpen;
    } else if (result == -2113929211) {
        return error.NotFound;
    } else if (result == -2113929210) {
        return error.InternalFail;
    } else if (result == -2113929209) {
        return error.NotAvailable;
    } else if (result == -2113929208) {
        return error.TimeOut;
    } else {
        std.debug.print("slang error unknown ({})\n", .{result});
        return error.Fail;
    }
}

pub const ShaderEntryPoint = struct {

    shader_library_base: ?*slang.ShaderLibrary = null,
    module_reference_base: ?*slang.ModuleReference = null,
    entry_point_reference_base: ?*slang.EntryPointReference = null,

    pub fn getShaderCode(self: *const ShaderEntryPoint, allocator: *std.mem.Allocator) ![]u8 {
        const allocatorInfo = slang.AllocatorInfo{
            .Allocate = allocate,
            .Free = free,
            .UserData = @as(?*anyopaque, @ptrCast(allocator)),
        };

        var slang_result: slang.ShaderLibraryResult = 0;
        var size: usize = undefined;
        const shader_code = slang.ShaderLibrary_createEntryPointCode(
            self.shader_library_base,
            self.module_reference_base,
            self.entry_point_reference_base,
            &slang_result,
            &size,
            &allocatorInfo
        );
        if (slang_result != 0) {
            try createSlangResult(slang_result);
        }

        return shader_code[0..size];
    }

    fn allocate(size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const allocator: *std.mem.Allocator = @ptrCast(@alignCast(user_data));
        const result = allocator.alloc(u8, size) catch {
            return null;
        };

        return @ptrCast(result.ptr);
    }

    fn free(memory: ?*anyopaque, size: usize, user_data: ?*anyopaque) callconv(.c) void {
        const allocator: *std.mem.Allocator = @ptrCast(@alignCast(user_data));
        const data1: [*]u8 = @ptrCast(@alignCast(memory));
        const data2 = data1[0..size];
        allocator.free(data2);
    }

};

pub const ShaderModule = struct {

    shader_library_base: ?*slang.ShaderLibrary = null,
    module_reference_base: ?*slang.ModuleReference = null,

    pub fn loadEntryPoint(self: *const ShaderModule, name: [:0]const u8) !ShaderEntryPoint {
        const name_cstr: [*c]const u8 = name;

        var result: slang.ShaderLibraryResult = undefined;
        const reference = slang.ShaderLibrary_loadEntryPoint(self.shader_library_base, self.module_reference_base, name_cstr, &result);
        if (result != 0) {
            try createSlangResult(result);
        }

        return ShaderEntryPoint{
            .shader_library_base = self.shader_library_base,
            .module_reference_base = self.module_reference_base,
            .entry_point_reference_base = reference
        };
    }

};

pub const ShaderLibrary = struct {

    shader_library_base: ?*slang.ShaderLibrary = null,

    pub fn init(allocator: std.mem.Allocator) !ShaderLibrary {
        var self = ShaderLibrary{};

        var search_paths: [][*c]const u8 = try allocator.alloc([*c]const u8, 1);
        defer allocator.free(search_paths);
        search_paths[0] = "shaders/";

        const search_paths_ptr: [*c][*c]const u8 = search_paths.ptr;

        var targets = [_]slang.ShaderTarget{
            .{
                .CompileTarget = 6,
                .ProfileName = "glsl_450",
                .FloatingPointMode = 0,
                .LineDirectiveMode = 0,
                .ForceGLSLScalarBufferLayout = 0
            }
        };

        const create_info = slang.ShaderLibraryInfo{
            .SearchPaths = search_paths_ptr,
            .SearchPathsCount = search_paths.len,
            .Targets = &targets,
            .TargetCount = 1,
            .DefaultMatrixLayoutMode = 2
        };

        var result: slang.ShaderLibraryResult = undefined;
        self.shader_library_base = slang.ShaderLibrary_init(&create_info, &result);
        if (result != 0) {
            try createSlangResult(result);
        }

        return self;
    }

    pub fn deinit(self: *const ShaderLibrary) void {
        slang.ShaderLibrary_deinit(self.shader_library_base);
    }

    pub fn loadModule(self: *const ShaderLibrary, module_name: [:0]const u8) !ShaderModule {
        const module_name_cstr: [*c]const u8 = module_name;

        var result: slang.ShaderLibraryResult = undefined;
        const reference = slang.ShaderLibrary_loadModule(self.shader_library_base, module_name_cstr, &result);
        if (result != 0) {
            try createSlangResult(result);
        }

        return ShaderModule{
            .shader_library_base = self.shader_library_base,
            .module_reference_base = reference
        };
    }

};
