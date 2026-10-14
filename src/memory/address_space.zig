const std = @import("std");

pub const page_size = 0x1000;
pub const address_limit: u64 = 1 << 39;
pub const Permissions = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,

    pub fn bits(self: Permissions) u32 {
        return @as(u32, @intFromBool(self.read)) | (@as(u32, @intFromBool(self.write)) << 1) | (@as(u32, @intFromBool(self.execute)) << 2);
    }
};

pub const Info = struct { base: u64, size: u64, permissions: Permissions, state: u32 };
const Region = struct { base: u64, bytes: []u8, permissions: Permissions, state: u32 };
const Access = enum { read, write, execute };

pub const Memory = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(Region) = .empty,
    mapped_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        for (self.regions.items) |region| self.allocator.free(region.bytes);
        self.regions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn map(self: *Memory, address: u64, size: usize, permissions: Permissions) !void {
        return self.mapWithState(address, size, permissions, 5);
    }

    pub fn mapWithState(self: *Memory, address: u64, size: usize, permissions: Permissions, state: u32) !void {
        if (size == 0 or address % page_size != 0 or size % page_size != 0) return error.InvalidMapping;
        const end = std.math.add(u64, address, size) catch return error.InvalidMapping;
        if (end > address_limit) return error.InvalidMapping;
        if (size > 256 * 1024 * 1024 or self.mapped_bytes + size > 512 * 1024 * 1024) return error.MemoryLimit;
        var index: usize = 0;
        for (self.regions.items) |region| {
            if (address < region.base + region.bytes.len and region.base < end) return error.OverlappingMapping;
            if (region.base < address) index += 1;
        }
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);
        try self.regions.insert(self.allocator, index, .{ .base = address, .bytes = bytes, .permissions = permissions, .state = state });
        self.mapped_bytes += size;
    }

    pub fn protect(self: *Memory, address: u64, size: usize, permissions: Permissions) !void {
        for (self.regions.items) |*region| {
            if (region.base == address and region.bytes.len == size) {
                region.permissions = permissions;
                return;
            }
        }
        return error.InvalidMapping;
    }

    pub fn unmap(self: *Memory, address: u64, size: usize) !void {
        for (self.regions.items, 0..) |region, index| {
            if (region.base == address and region.bytes.len == size) {
                self.allocator.free(region.bytes);
                _ = self.regions.orderedRemove(index);
                self.mapped_bytes -= size;
                return;
            }
        }
        return error.InvalidMapping;
    }

    pub fn query(self: *const Memory, address: u64) !Info {
        if (address >= address_limit) return error.MemoryFault;
        var previous_end: u64 = 0;
        for (self.regions.items) |region| {
            if (address < region.base) return .{ .base = previous_end, .size = region.base - previous_end, .permissions = .{}, .state = 0 };
            if (address < region.base + region.bytes.len) return .{ .base = region.base, .size = region.bytes.len, .permissions = region.permissions, .state = region.state };
            previous_end = region.base + region.bytes.len;
        }
        return .{ .base = previous_end, .size = address_limit - previous_end, .permissions = .{}, .state = 0 };
    }

    fn regionAt(self: *const Memory, address: u64) ?usize {
        for (self.regions.items, 0..) |region, index| {
            if (address >= region.base and address - region.base < region.bytes.len) return index;
        }
        return null;
    }

    fn validate(self: *const Memory, address: u64, length: usize, access: Access) !void {
        const end = std.math.add(u64, address, length) catch return error.MemoryFault;
        if (end > address_limit) return error.MemoryFault;
        var cursor = address;
        while (cursor < end) {
            const region = self.regions.items[self.regionAt(cursor) orelse return error.MemoryFault];
            const allowed = switch (access) {
                .read => region.permissions.read,
                .write => region.permissions.write,
                .execute => region.permissions.execute,
            };
            if (!allowed) return error.AccessDenied;
            cursor = @min(end, region.base + region.bytes.len);
        }
    }

    pub fn read(self: *const Memory, address: u64, output: []u8) !void {
        try self.validate(address, output.len, .read);
        self.copyOut(address, output);
    }

    fn copyOut(self: *const Memory, address: u64, output: []u8) void {
        var copied: usize = 0;
        while (copied < output.len) {
            const cursor = address + copied;
            const region = self.regions.items[self.regionAt(cursor).?];
            const offset: usize = @intCast(cursor - region.base);
            const count = @min(output.len - copied, region.bytes.len - offset);
            @memcpy(output[copied..][0..count], region.bytes[offset..][0..count]);
            copied += count;
        }
    }

    pub fn write(self: *Memory, address: u64, input: []const u8) !void {
        try self.validate(address, input.len, .write);
        var copied: usize = 0;
        while (copied < input.len) {
            const cursor = address + copied;
            const region = &self.regions.items[self.regionAt(cursor).?];
            const offset: usize = @intCast(cursor - region.base);
            const count = @min(input.len - copied, region.bytes.len - offset);
            @memcpy(region.bytes[offset..][0..count], input[copied..][0..count]);
            copied += count;
        }
    }

    pub fn readInt(self: *const Memory, comptime T: type, address: u64) !T {
        if (self.regionAt(address)) |index| {
            const region = self.regions.items[index];
            const offset: usize = @intCast(address - region.base);
            if (@sizeOf(T) <= region.bytes.len - offset) {
                if (!region.permissions.read) return error.AccessDenied;
                return std.mem.readInt(T, region.bytes[offset..][0..@sizeOf(T)], .little);
            }
        }
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(T, &bytes, .little);
    }

    pub fn writeInt(self: *Memory, comptime T: type, address: u64, value: T) !void {
        if (self.regionAt(address)) |index| {
            const region = &self.regions.items[index];
            const offset: usize = @intCast(address - region.base);
            if (@sizeOf(T) <= region.bytes.len - offset) {
                if (!region.permissions.write) return error.AccessDenied;
                std.mem.writeInt(T, region.bytes[offset..][0..@sizeOf(T)], value, .little);
                return;
            }
        }
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try self.write(address, &bytes);
    }

    pub fn fetch(self: *const Memory, address: u64) !u32 {
        if (address & 3 != 0) return error.UnalignedInstruction;
        const region = self.regions.items[self.regionAt(address) orelse return error.MemoryFault];
        if (!region.permissions.execute) return error.AccessDenied;
        const offset: usize = @intCast(address - region.base);
        if (region.bytes.len - offset < 4) return error.MemoryFault;
        return std.mem.readInt(u32, region.bytes[offset..][0..4], .little);
    }
};

test "mapping validates address range, overlap, and page alignment" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, page_size, .{ .read = true, .write = true });
    try std.testing.expectError(error.OverlappingMapping, memory.map(0x1000, page_size, .{}));
    try std.testing.expectError(error.InvalidMapping, memory.map(0x2001, page_size, .{}));
    try std.testing.expectError(error.InvalidMapping, memory.map(address_limit, page_size, .{}));
    try std.testing.expectError(error.InvalidMapping, memory.map(0xfffffffffffff000, page_size, .{}));
}

test "permissions apply independently to instruction fetch and data" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, page_size, .{ .read = true, .write = true });
    try memory.writeInt(u32, 0x1000, 0xd503201f);
    try std.testing.expectError(error.AccessDenied, memory.fetch(0x1000));
    try memory.protect(0x1000, page_size, .{ .execute = true });
    try std.testing.expectEqual(@as(u32, 0xd503201f), try memory.fetch(0x1000));
    try std.testing.expectError(error.AccessDenied, memory.readInt(u32, 0x1000));
    try std.testing.expectError(error.AccessDenied, memory.writeInt(u32, 0x1000, 0));
}

test "cross region writes check the whole range before modifying data" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, page_size, .{ .read = true, .write = true });
    try memory.map(0x2000, page_size, .{ .read = true, .write = true });
    try memory.writeInt(u64, 0x1ffc, 0x0123456789abcdef);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), try memory.readInt(u64, 0x1ffc));
    try memory.protect(0x2000, page_size, .{ .read = true });
    try std.testing.expectError(error.AccessDenied, memory.writeInt(u64, 0x1ffc, 0));
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), try memory.readInt(u64, 0x1ffc));
    try memory.protect(0x2000, page_size, .{ .read = true, .write = true });
    try std.testing.expectError(error.MemoryFault, memory.writeInt(u64, 0x2ffc, 0));
}

test "query reports mapped regions and surrounding free spans" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, page_size, .{ .read = true });
    try std.testing.expectEqual(@as(u64, 0x1000), (try memory.query(0)).size);
    try std.testing.expectEqual(@as(u32, 5), (try memory.query(0x1800)).state);
    try memory.unmap(0x1000, page_size);
    try std.testing.expectEqual(address_limit, (try memory.query(0)).size);
}
