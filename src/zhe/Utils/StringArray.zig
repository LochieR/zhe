const std = @import("std");

pub const StringArray = struct {

    allocator: *std.mem.Allocator,
    string_ptrs: std.ArrayList([*:0]const u8),
    strings: std.ArrayList([]u8),

    pub fn init(allocator: *std.mem.Allocator) !StringArray {
        return StringArray{
            .allocator = allocator,
            .string_ptrs = try std.ArrayList([*:0]const u8).initCapacity(allocator.*, 4),
            .strings = try std.ArrayList([]u8).initCapacity(allocator.*, 4),
        };
    }

    pub fn deinit(self: *StringArray) void {
        for (self.strings.items) |str| {
            self.allocator.free(str);
        }

        self.strings.deinit(self.allocator.*);
        self.string_ptrs.deinit(self.allocator.*);
    }

    pub fn append(self: *StringArray, value: []const u8) !void {
        var mem = try self.allocator.alloc(u8, value.len + 1);

        std.mem.copyForwards(u8, mem[0..value.len], value);
        mem[value.len] = 0;

        const cstr: [*:0]const u8 = @ptrCast(mem.ptr);
        try self.strings.append(self.allocator.*, mem);
        try self.string_ptrs.append(self.allocator.*, cstr);
    }

    pub fn asCStringArray(self: *const StringArray) [*][*:0]const u8 {
        return self.string_ptrs.items.ptr;
    }

    pub fn len(self: *const StringArray) usize {
        return self.strings.items.len;
    }

};
