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

const Device = @import("Device.zig").Device;
const ResourceFreeContext = @import("Device.zig").ResourceFreeContext;
const pickPhysicalDevice = @import("Device.zig").pickPhysicalDevice;
const findQueueFamilies = @import("Device.zig").findQueueFamilies;

pub const InstanceError = error {
    SurfaceCreationFailed,
    ValidationNotSupported,
};

pub const MaxFramesInFlight: u32 = 2;

const Allocator = std.mem.Allocator;

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_types;
    _ = p_user_data;

    if (message_severity.info_bit_ext or message_severity.verbose_bit_ext) {
        return .false;
    }

    if (message_severity.error_bit_ext) {
        if (p_callback_data) |data| {
            if (data.p_message) |message| {
                std.debug.print("\x1b[31m[Validation Layer] {s}\x1b[0m\n", .{message});
            }
        }
    }

    return .false;
}

pub const InstanceInfo = struct {
    app_name: [*:0]const u8,
    window: *c.GLFWwindow,
    allocator: Allocator,
};

pub const Instance = struct {

    allocator: Allocator,
    vk_base: vk.BaseWrapper,

    instance: vk.InstanceProxy,
    window: *c.GLFWwindow,
    surface: vk.SurfaceKHR,

    debug_messenger: vk.DebugUtilsMessengerEXT,

    vk_allocator: ?*vk.AllocationCallbacks = null,

    pub fn init(info: *const InstanceInfo) !Instance {
        var self: Instance = undefined;
        self.allocator = info.allocator;
        self.window = info.window;
        self.vk_allocator = null;

        self.vk_base = vk.BaseWrapper.load(glfw.glfwGetInstanceProcAddress);

        const app_info: vk.ApplicationInfo = .{
            .p_application_name = info.app_name,
            .application_version = @bitCast(vk.makeApiVersion(1, 0, 0, 0)),
            .p_engine_name = null,
            .engine_version = 0,
            .api_version = @bitCast(vk.API_VERSION_1_4)
        };

        var instance_info: vk.InstanceCreateInfo = .{
            .p_application_info = &app_info
        };

        var instance_extensions = std.array_list.Managed([*:0]const u8).init(info.allocator);
        defer instance_extensions.deinit();

        var glfw_extension_count: u32 = undefined;
        const glfw_extensions = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);
        try instance_extensions.appendSlice(@ptrCast(glfw_extensions[0..glfw_extension_count]));

        if (builtin.mode == .Debug) {
            try instance_extensions.append(vk.extensions.ext_debug_utils.name);
        }

        instance_info.enabled_extension_count = @intCast(instance_extensions.items.len);
        instance_info.pp_enabled_extension_names = instance_extensions.items.ptr;

        var validation_layers = try utils.StringArray.init(&self.allocator);
        defer validation_layers.deinit();
        try validation_layers.append("VK_LAYER_KHRONOS_validation");

        var debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT = undefined;
        if (builtin.mode == .Debug) {
            if (!try checkValidationLayerSupport(&self)) {
                return error.ValidationNotSupported;
            }

            instance_info.enabled_layer_count = @intCast(validation_layers.len());
            instance_info.pp_enabled_layer_names = validation_layers.asCStringArray();

            populateDebugMessengerCreateInfo(&debug_create_info);
            instance_info.p_next = &debug_create_info;
        } else {
            instance_info.enabled_layer_count = 0;
            instance_info.pp_enabled_layer_names = null;
        }

        const instance = try self.vk_base.createInstance(&instance_info, self.vk_allocator);

        const instance_wrapper = try info.allocator.create(vk.InstanceWrapper);
        errdefer info.allocator.destroy(instance_wrapper);
        instance_wrapper.* = vk.InstanceWrapper.load(instance, self.vk_base.dispatch.vkGetInstanceProcAddr.?);
        self.instance = vk.InstanceProxy.init(instance, instance_wrapper);
        errdefer self.instance.destroyInstance(null);

        if (builtin.mode == .Debug) {
            self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&debug_create_info, self.vk_allocator);
        }

        const result = glfw.glfwCreateWindowSurface(self.instance.handle, @ptrCast(self.window), self.vk_allocator, &self.surface);
        if (result != .success) {
            return error.SurfaceCreationFailed;
        }

        return self;
    }

    pub fn deinit(self: *Instance) void {
        self.instance.destroySurfaceKHR(self.surface, self.vk_allocator);

        if (builtin.mode == .Debug) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, self.vk_allocator);
        }

        self.instance.destroyInstance(self.vk_allocator);
        self.allocator.destroy(self.instance.wrapper);
    }

    pub fn createDevice(self: *Instance) !Device {
        const physical_device = try pickPhysicalDevice(self.instance, self.allocator, self.surface);

        const indices = try findQueueFamilies(self.instance, self.allocator, physical_device, self.surface);

        var queue_create_infos = std.array_list.Managed(vk.DeviceQueueCreateInfo).init(self.allocator);
        defer queue_create_infos.deinit();

        const priority = [_]f32{ 1.0 };
        if (indices.graphics_family == indices.present_family) {
            const createInfo: vk.DeviceQueueCreateInfo = .{
                .s_type = .device_queue_create_info,
                .queue_family_index = indices.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority
            };

            try queue_create_infos.append(createInfo);
        } else {
            var create_info: vk.DeviceQueueCreateInfo = .{
                .s_type = .device_queue_create_info,
                .queue_family_index = indices.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority
            };

            try queue_create_infos.append(create_info);

            create_info = .{
                .s_type = .device_queue_create_info,
                .queue_family_index = indices.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority
            };

            try queue_create_infos.append(create_info);
        }

        const device_features: vk.PhysicalDeviceFeatures = .{
            .sampler_anisotropy = .true,
            .sample_rate_shading = .true
        };

        var device_extensions = try utils.StringArray.init(&self.allocator);
        defer device_extensions.deinit();
        try device_extensions.append("VK_KHR_swapchain");

        var device_info: vk.DeviceCreateInfo = .{
            .s_type = .device_create_info,
            .queue_create_info_count = @intCast(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .p_enabled_features = &device_features,
            .enabled_extension_count = @intCast(device_extensions.len()),
            .pp_enabled_extension_names = device_extensions.asCStringArray(),
            .p_next = null,
        };

        var validation_layers = try utils.StringArray.init(&self.allocator);
        defer validation_layers.deinit();
        try validation_layers.append("VK_LAYER_KHRONOS_validation");

        if (builtin.mode == .Debug) {
            device_info.enabled_layer_count = @intCast(validation_layers.len());
            device_info.pp_enabled_layer_names = validation_layers.asCStringArray();
        }
        else {
            device_info.pp_enabled_layer_names = null;
            device_info.enabled_layer_count = 0;
        }

        const device = try self.instance.createDevice(physical_device, &device_info, self.vk_allocator);
        const device_wrapper = try self.allocator.create(vk.DeviceWrapper);
        errdefer self.allocator.destroy(device_wrapper);
        device_wrapper.* = vk.DeviceWrapper.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

        const device_proxy = vk.DeviceProxy.init(device, device_wrapper);
        errdefer device_proxy.destroyDevice(null);

        const graphics_queue = device_proxy.getDeviceQueue(indices.graphics_family, 0);
        const present_queue = device_proxy.getDeviceQueue(indices.present_family, 0);

        const command_pool_info: vk.CommandPoolCreateInfo = .{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = 0
        };

        const command_pool = try device_proxy.createCommandPool(&command_pool_info, self.vk_allocator);
        errdefer device_proxy.destroyCommandPool(command_pool, self.vk_allocator);

        const pool_sizes = [_]vk.DescriptorPoolSize {
            vk.DescriptorPoolSize{
                .type = .combined_image_sampler,
                .descriptor_count = 1000
            },
            vk.DescriptorPoolSize{
                .type = .uniform_buffer,
                .descriptor_count = 1000
            },
            vk.DescriptorPoolSize{
                .type = .sampler,
                .descriptor_count = 1000
            },
            vk.DescriptorPoolSize{
                .type = .storage_buffer,
                .descriptor_count = 1000
            }
        };

        const descriptor_pool_info: vk.DescriptorPoolCreateInfo = .{
            .pool_size_count = @intCast(pool_sizes.len),
            .p_pool_sizes = &pool_sizes,
            .max_sets = @intCast(1000 * pool_sizes.len)
        };

        const descriptor_pool = try device_proxy.createDescriptorPool(&descriptor_pool_info, self.vk_allocator);
        errdefer device_proxy.destroyDescriptorPool(descriptor_pool, self.vk_allocator);

        var device_obj: Device = .{
            .allocator = self.allocator,
            .instance = self,
            .device = device_proxy,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .physical_device = physical_device,
            .command_pool = command_pool,
            .descriptor_pool = descriptor_pool,
            .frame_index = 0,
            .skip_frame = false,
            .image_available_semaphores = .{ .null_handle, .null_handle },
            .render_finished_semaphores = .{ .null_handle, .null_handle },
            .in_flight_fences = .{ .null_handle, .null_handle }
        };

        const semaphore_info = vk.SemaphoreCreateInfo{};
        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true }
        };

        for (0..MaxFramesInFlight) |i| {
            device_obj.image_available_semaphores[i] = try device_proxy.createSemaphore(&semaphore_info, self.vk_allocator);
            device_obj.render_finished_semaphores[i] = try device_proxy.createSemaphore(&semaphore_info, self.vk_allocator);
            device_obj.in_flight_fences[i] = try device_proxy.createFence(&fence_info, self.vk_allocator);
        }

        errdefer {
            for (0..MaxFramesInFlight) |i| {
                device_proxy.destroySemaphore(device_obj.image_available_semaphores[i], self.vk_allocator);
                device_proxy.destroySemaphore(device_obj.render_finished_semaphores[i], self.vk_allocator);
                device_proxy.destroyFence(device_obj.in_flight_fences[i], self.vk_allocator);
            }
        }

        const device_name = try device_obj.getPhysicalDeviceName(self.allocator);
        std.debug.print("Using GPU: {s}\n", .{device_name});
        self.allocator.free(@as([]const u8, @ptrCast(device_name)));

        return device_obj;
    }

    pub fn destroyDevice(self: *const Instance, device: *Device) void {
        for (0..MaxFramesInFlight) |i| {
            device.device.destroySemaphore(device.image_available_semaphores[i], self.vk_allocator);
            device.device.destroySemaphore(device.render_finished_semaphores[i], self.vk_allocator);
            device.device.destroyFence(device.in_flight_fences[i], self.vk_allocator);
        }

        device.device.destroyDescriptorPool(device.descriptor_pool, self.vk_allocator);
        device.device.destroyCommandPool(device.command_pool, self.vk_allocator);

        device.device.destroyDevice(self.vk_allocator);
        self.allocator.destroy(device.device.wrapper);
    }

    fn checkValidationLayerSupport(self: *Instance) !bool {
        const availableLayers = try self.vk_base.enumerateInstanceLayerPropertiesAlloc(self.allocator);
        defer self.allocator.free(availableLayers);

        var validationLayers = try utils.StringArray.init(&self.allocator);
        defer validationLayers.deinit();
        try validationLayers.append("VK_LAYER_KHRONOS_validation");

        for (0..validationLayers.len(), validationLayers.string_ptrs.items) |_, layerName| {
            var layerFound = false;

            for (availableLayers) |layerProperties| {
                const validationSlice = layerName[0..std.mem.len(layerName)];
                const availableSlice = std.mem.sliceTo(&layerProperties.layer_name, 0);

                if (std.mem.eql(u8, validationSlice, availableSlice)) {
                    layerFound = true;
                    break;
                }
            }
            if (!layerFound) {
                return false;
            }
        }

        return true;
    }

    fn populateDebugMessengerCreateInfo(create_info: *vk.DebugUtilsMessengerCreateInfoEXT) void {
        const severity: vk.DebugUtilsMessageSeverityFlagsEXT = .{
            .verbose_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true
        };

        const messageType: vk.DebugUtilsMessageTypeFlagsEXT = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true
        };

        create_info.s_type = .debug_utils_messenger_create_info_ext;
        create_info.message_severity = severity;
        create_info.message_type = messageType;
        create_info.pfn_user_callback = debugCallback;
        create_info.flags = .{};
        create_info.p_user_data = null;
        create_info.p_next = null;
    }

};
