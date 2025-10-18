const std = @import("std");
const vk = @import("vulkan");

const Device = @import("Device.zig").Device;

const needsStagingBuffer = @import("Device.zig").needsStagingBuffer;

pub const BufferType = enum(u8) {
    vertex_buffer  = 1 << 0,
    index_buffer   = 1 << 1,
    staging_buffer = 1 << 2,
    constant_buffer = 1 << 3,
    storage_buffer = 1 << 4
};

pub const Buffer = struct {

    device: *Device,
    buffer_type: BufferType,

    buffer: vk.Buffer = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    staging_buffer: vk.Buffer = .null_handle,
    staging_memory: vk.DeviceMemory = .null_handle,

    size: usize,

    pub fn setData(self: *Buffer, data: []const u8, offset: usize) !void {
        var memory = try self.map(data.len);
        std.mem.copyForwards(u8, memory[offset..(data.len + offset)], data);
        try self.unmap();
    }

    pub fn map(self: *Buffer, size: usize) ![*]u8 {
        if (needsStagingBuffer(self.buffer_type)) {
            const memory = try self.device.device.mapMemory(self.staging_memory, 0, @intCast(size), .{});
            return @as([*c]u8, @ptrCast(memory))[0..size].ptr;
        } else {
            const memory = try self.device.device.mapMemory(self.memory, 0, @intCast(size), .{});
            return @as([*c]u8, @ptrCast(memory))[0..size].ptr;
        }
    }

    pub fn unmap(self: *Buffer) !void {
        if (needsStagingBuffer(self.buffer_type)) {
            self.device.device.unmapMemory(self.staging_memory);

            var command_list = self.device.beginSingleTimeCommands();
            const buffer_copy = try self.device.nativeBufferCopy(self.staging_buffer, self.buffer, self.size, 0, 0);

            try command_list.submitNativeCommand(&buffer_copy);
            try self.device.endSingleTimeCommands(&command_list);
        } else {
            self.device.device.unmapMemory(self.memory);
        }
    }

};
