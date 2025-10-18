const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        //.default_target = .{ .os_tag = .windows, .abi = .msvc }
    });
    const optimize = b.standardOptimizeOption(.{});

    const cmake_build_type = switch(optimize) {
        .Debug => "Release",
        .ReleaseFast => "Release",
        .ReleaseSafe => "Release",
        .ReleaseSmall => "Release",
    };

    var cmake_arg = std.array_list.Managed(u8).init(b.allocator);
    defer cmake_arg.deinit();

    std.fmt.format(cmake_arg.writer(), "-DCMAKE_BUILD_TYPE={s}", .{ cmake_build_type }) catch {
        @panic("error formatting");
    };

    const slang_cmake_build = b.addSystemCommand(&[_][]const u8{
        "cmake",
        "-S",
        "deps/slang",
        "-B",
        "deps/slang/build",
        "-DSLANG_LIB_TYPE=STATIC",
        "-DSLANG_ENABLE_EXAMPLES=OFF",
        "-DSLANG_ENABLE_TESTS=OFF",
        cmake_arg.items
    });

    const slang_cmake_compile = b.addSystemCommand(&[_][]const u8{
        "cmake",
        "--build",
        "deps/slang/build",
        "--config",
        cmake_build_type,
        "--parallel",
        "8"
    });
    slang_cmake_compile.step.dependOn(&slang_cmake_build.step);

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/zhe/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/zheditor/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("zhe", lib_mod);

    const vkPath = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch |err| {
        if (err == std.process.GetEnvVarOwnedError.EnvironmentVariableNotFound) {
            @panic("could not find environment variable");
        } else if (err == std.process.GetEnvVarOwnedError.InvalidWtf8) {
            @panic("invalid wtf8");
        } else {
            @panic("out of memory");
        }
    };

    var list = std.array_list.Managed(u8).init(b.allocator);
    defer list.deinit();

    std.fmt.format(list.writer(), "{s}/share/vulkan/registry/vk.xml", .{vkPath}) catch {
        @panic("error formatting");
    };

    const vulkan = b.dependency("vulkan", .{
        .registry = @as([]const u8, list.items),
    }).module("vulkan-zig");
    exe_mod.addImport("vulkan", vulkan);
    lib_mod.addImport("vulkan", vulkan);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zhe",
        .root_module = lib_mod,
    });
    lib.addIncludePath(b.path("deps/glfw/include"));
    lib.addIncludePath(b.path("deps/slang_bridge/include"));

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "zheditor",
        .root_module = exe_mod,
    });

    const glfw_c = b.addLibrary(.{
        .linkage = .static,
        .name = "glfw",
        .root_module = b.addModule("glfw", .{
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });

    glfw_c.root_module.addIncludePath(b.path("deps/glfw/include"));
    glfw_c.root_module.addCSourceFiles(.{
        .files = &.{
            "deps/glfw/src/context.c",
            "deps/glfw/src/init.c",
            "deps/glfw/src/input.c",
            "deps/glfw/src/monitor.c",

            "deps/glfw/src/null_init.c",
            "deps/glfw/src/null_joystick.c",
            "deps/glfw/src/null_monitor.c",
            "deps/glfw/src/null_window.c",

            "deps/glfw/src/platform.c",
            "deps/glfw/src/vulkan.c",
            "deps/glfw/src/window.c"
        },
        .language = .c,
    });

    if (target.result.os.tag == .windows) {
        glfw_c.root_module.addCSourceFiles(.{
            .files = &.{
                "deps/glfw/src/win32_init.c",
                "deps/glfw/src/win32_joystick.c",
                "deps/glfw/src/win32_module.c",
                "deps/glfw/src/win32_monitor.c",
                "deps/glfw/src/win32_time.c",
                "deps/glfw/src/win32_thread.c",
                "deps/glfw/src/win32_window.c",
                "deps/glfw/src/wgl_context.c",
                "deps/glfw/src/egl_context.c",
                "deps/glfw/src/osmesa_context.c"
            },
            .language = .c
        });

        glfw_c.root_module.addCMacro("_GLFW_WIN32", "");

        glfw_c.root_module.linkSystemLibrary("gdi32", .{});
        glfw_c.root_module.linkSystemLibrary("user32", .{});
        glfw_c.root_module.linkSystemLibrary("kernel32", .{});
        glfw_c.root_module.linkSystemLibrary("shell32", .{});

        exe.root_module.linkSystemLibrary("dwmapi", .{});
    } else if (target.result.os.tag == .linux) {
        glfw_c.root_module.addCSourceFiles(.{
            .files = &.{
                "deps/glfw/src/x11_init.c",
                "deps/glfw/src/x11_monitor.c",
                "deps/glfw/src/x11_window.c",
                "deps/glfw/src/xkb_unicode.c",
                "deps/glfw/src/posix_module.c",
                "deps/glfw/src/posix_time.c",
                "deps/glfw/src/posix_thread.c",
                "deps/glfw/src/posix_module.c",
                "deps/glfw/src/glx_context.c",
                "deps/glfw/src/egl_context.c",
                "deps/glfw/src/osmesa_context.c",
                "deps/glfw/src/linux_joystick.c"
            },
            .language = .c
        });

        glfw_c.root_module.addCMacro("_GLFW_X11", "");
    } else if (target.result.os.tag == .macos) {
        glfw_c.root_module.addCSourceFiles(.{
            .files = &.{
                "deps/glfw/src/cocoa_init.m",
                "deps/glfw/src/cocoa_monitor.m",
                "deps/glfw/src/cocoa_window.m",
                "deps/glfw/src/cocoa_joystick.m",
                "deps/glfw/src/cocoa_time.c",
                "deps/glfw/src/nsgl_context.m",
                "deps/glfw/src/posix_thread.c",
                "deps/glfw/src/posix_module.c",
                "deps/glfw/src/osmesa_context.c",
                "deps/glfw/src/egl_context.c"
            },
            .language = .c
        });

        glfw_c.root_module.addCMacro("_GLFW_COCOA", "");
    }

    exe.root_module.linkLibrary(glfw_c);
    exe.root_module.addIncludePath(b.path("deps/glfw/include"));

    exe.root_module.addLibraryPath(b.path("lib"));
    exe.root_module.linkSystemLibrary("slang", .{});

    const slang_bridge = b.addLibrary(.{
        .name = "slang",
        .linkage = .static,
        .root_module = b.addModule("slang", .{
            .link_libc = true,
            .link_libcpp = true,
            .target = target,
            .optimize = optimize
        }),
    });

    slang_bridge.root_module.addIncludePath(b.path("deps/slang_bridge/include"));
    slang_bridge.root_module.addIncludePath(b.path("deps/slang/include"));
    slang_bridge.root_module.addCSourceFiles(.{
        .files = &.{
            "deps/slang_bridge/src/ShaderLibrary.cpp",
            "deps/slang_bridge/src/slang_bridge.cpp"
        },
        .language = .cpp
    });

    //slang_bridge.step.dependOn(&slang_cmake_compile.step);

    lib.root_module.linkLibrary(slang_bridge);
    exe.root_module.linkLibrary(slang_bridge);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
