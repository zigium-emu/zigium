const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;
const Permissions = @import("../memory/address_space.zig").Permissions;

pub const heap_base: u64 = 0x7200000000;
pub const heap_size: usize = 64 * 1024 * 1024;
pub const stack_base: u64 = 0x7300000000;
pub const stack_size: usize = 1024 * 1024;
pub const tls_base: u64 = 0x7400000000;
pub const config_base: u64 = tls_base + 0x1000;
pub const main_thread_handle: u32 = 0x100;
pub const entry_x1: u64 = std.math.maxInt(u64);
pub const entry_lr: u64 = 0;
pub const config_entry_size: u64 = 24;

pub const ConfigKey = enum(u32) {
    end_of_list = 0,
    main_thread_handle = 1,
    override_heap = 3,
    applet_type = 7,
};

pub const Environment = struct {
    config: u64,
    stack_top: u64,
    tls: u64,
    heap: u64,
};

const Entry = struct {
    key: ConfigKey,
    mandatory: bool = false,
    values: [2]u64,
};

pub fn setup(memory: *Memory) !Environment {
    const rw: Permissions = .{ .read = true, .write = true, .execute = false };
    try memory.map(heap_base, heap_size, rw);
    errdefer memory.unmap(heap_base, heap_size) catch {};
    try memory.mapWithState(stack_base, stack_size, rw, 0x0b);
    errdefer memory.unmap(stack_base, stack_size) catch {};
    try memory.mapWithState(tls_base, 0x1000, rw, 0x0c);
    errdefer memory.unmap(tls_base, 0x1000) catch {};
    try memory.mapWithState(config_base, 0x1000, rw, 0x02);
    errdefer memory.unmap(config_base, 0x1000) catch {};
    const info_address = config_base + 0x200;
    const info = "Zigium homebrew environment";
    const entries = [_]Entry{
        .{ .key = .main_thread_handle, .values = .{ main_thread_handle, 0 } },
        // The loader supplies a bounded heap instead of claiming SetHeapSize
        // can safely resize it while other process mappings remain active.
        .{ .key = .override_heap, .mandatory = true, .values = .{ heap_base, heap_size } },
        .{ .key = .applet_type, .values = .{ 0, 0 } },
        .{ .key = .end_of_list, .values = .{ info_address, info.len } },
    };
    for (entries, 0..) |entry, i| {
        const address = config_base + i * config_entry_size;
        try memory.writeInt(u32, address, @backingInt(entry.key));
        try memory.writeInt(u32, address + 4, if (entry.mandatory) 1 else 0);
        try memory.writeInt(u64, address + 8, entry.values[0]);
        try memory.writeInt(u64, address + 16, entry.values[1]);
    }
    try memory.write(info_address, info ++ "\x00");
    try memory.protect(config_base, 0x1000, .{ .read = true, .write = false, .execute = false });
    return .{
        .config = config_base,
        .stack_top = stack_base + stack_size,
        .tls = tls_base,
        .heap = heap_base,
    };
}

test "homebrew ABI config uses 24-byte little endian tuples and required keys" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    const environment = try setup(&memory);
    try std.testing.expectEqual(config_base, environment.config);
    try std.testing.expectEqual(stack_base + stack_size, environment.stack_top);
    try std.testing.expectEqual(@as(u64, 0), environment.stack_top & 15);
    try std.testing.expectEqual(tls_base, environment.tls);
    try std.testing.expectEqual(heap_base, environment.heap);
    try std.testing.expectEqual(@as(u32, 1), try memory.readInt(u32, config_base));
    try std.testing.expectEqual(@as(u64, main_thread_handle), try memory.readInt(u64, config_base + 8));
    const heap_entry = config_base + config_entry_size;
    try std.testing.expectEqual(@as(u32, 3), try memory.readInt(u32, heap_entry));
    try std.testing.expectEqual(@as(u32, 1), try memory.readInt(u32, heap_entry + 4));
    try std.testing.expectEqual(heap_base, try memory.readInt(u64, heap_entry + 8));
    try std.testing.expectEqual(@as(u64, heap_size), try memory.readInt(u64, heap_entry + 16));
    try std.testing.expectEqual(@as(u32, 7), try memory.readInt(u32, config_base + 2 * config_entry_size));
    try std.testing.expectEqual(@as(u32, 0), try memory.readInt(u32, config_base + 3 * config_entry_size));
    try std.testing.expectEqual(@as(u64, 0), try memory.readInt(u64, tls_base));
    try std.testing.expectEqual(@as(u32, 0x0c), (try memory.query(tls_base)).state);
    try std.testing.expectEqual(@as(u32, 5), (try memory.query(heap_base)).state);
    try std.testing.expectEqual(@as(u64, 0), try memory.readInt(u64, heap_base));
    try memory.writeInt(u64, environment.stack_top - 8, 0x55);
    const config_denied = if (memory.writeInt(u32, config_base, 0)) |_| false else |_| true;
    try std.testing.expect(config_denied);
}

test "failed environment setup removes its mappings and preserves existing TLS" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(tls_base, 0x1000, .{ .read = true, .write = true });
    try memory.writeInt(u64, tls_base, 0x55);
    try std.testing.expectError(error.OverlappingMapping, setup(&memory));
    try std.testing.expectEqual(@as(u32, 0), (try memory.query(heap_base)).state);
    try std.testing.expectEqual(@as(u32, 0), (try memory.query(stack_base)).state);
    try std.testing.expectEqual(@as(u64, 0x55), try memory.readInt(u64, tls_base));
}
