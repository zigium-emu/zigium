const std = @import("std");

pub const shared_memory_size: usize = 0x40000;
pub const controller_offset: usize = 0x9a00;
pub const layout_size: usize = 0x350;
pub const sample_count: usize = 17;
pub const touchscreen_offset: usize = 0x400;
pub const touch_entry_size: usize = 0x298;
pub const Touch = struct { x: u32, y: u32 };
pub const Input = struct {
    buttons: u64,
    left_x: i32,
    left_y: i32,
    right_x: i32 = 0,
    right_y: i32 = 0,
    touch: ?Touch = null,
};

pub fn writeSample(bytes: []u8, sample: u64, elapsed_ns: u64, input: Input) !void {
    if (bytes.len != shared_memory_size) return error.InvalidSharedMemory;
    const index: usize = @intCast(sample % sample_count);
    const ticks: u64 = @intCast(@min((@as(u128, elapsed_ns) * 19_200_000) / 1_000_000_000, std.math.maxInt(u64)));
    writeTouchSample(bytes, sample, ticks, index, input.touch);
    std.mem.writeInt(u32, bytes[controller_offset..][0..4], 1, .little);
    std.mem.writeInt(u32, bytes[controller_offset + 12 ..][0..4], 0x232933, .little);
    std.mem.writeInt(u32, bytes[controller_offset + 16 ..][0..4], 0xeeeeee, .little);
    for (0..7) |layout_index| {
        const layout = controller_offset + 0x28 + layout_index * layout_size;
        const entry = layout + 0x20 + index * 0x30;
        std.mem.writeInt(u64, bytes[layout..][0..8], ticks, .little);
        std.mem.writeInt(u64, bytes[layout + 8 ..][0..8], @min(sample, sample_count), .little);
        std.mem.writeInt(u64, bytes[layout + 16 ..][0..8], index, .little);
        std.mem.writeInt(u64, bytes[layout + 24 ..][0..8], sample_count - 1, .little);
        std.mem.writeInt(u64, bytes[entry..][0..8], sample, .little);
        std.mem.writeInt(u64, bytes[entry + 8 ..][0..8], sample, .little);
        std.mem.writeInt(u64, bytes[entry + 16 ..][0..8], input.buttons, .little);
        std.mem.writeInt(i32, bytes[entry + 24 ..][0..4], std.math.clamp(input.left_x, -32767, 32767), .little);
        std.mem.writeInt(i32, bytes[entry + 28 ..][0..4], std.math.clamp(input.left_y, -32767, 32767), .little);
        std.mem.writeInt(i32, bytes[entry + 32 ..][0..4], std.math.clamp(input.right_x, -32767, 32767), .little);
        std.mem.writeInt(i32, bytes[entry + 36 ..][0..4], std.math.clamp(input.right_y, -32767, 32767), .little);
        std.mem.writeInt(u64, bytes[entry + 40 ..][0..8], 3, .little);
    }
}

fn writeTouchSample(bytes: []u8, sample: u64, ticks: u64, index: usize, touch: ?Touch) void {
    const entry = touchscreen_offset + 0x28 + index * touch_entry_size;
    @memset(bytes[entry..][0..touch_entry_size], 0);
    std.mem.writeInt(u64, bytes[entry..][0..8], sample, .little);
    if (touch) |point| {
        std.mem.writeInt(u64, bytes[entry + 8 ..][0..8], 1, .little);
        std.mem.writeInt(u64, bytes[entry + 0x10 ..][0..8], sample, .little);
        std.mem.writeInt(u32, bytes[entry + 0x20 ..][0..4], @min(point.x, 1279), .little);
        std.mem.writeInt(u32, bytes[entry + 0x24 ..][0..4], @min(point.y, 719), .little);
        std.mem.writeInt(u32, bytes[entry + 0x28 ..][0..4], 10, .little);
        std.mem.writeInt(u32, bytes[entry + 0x2c ..][0..4], 10, .little);
    }
    std.mem.writeInt(u64, bytes[touchscreen_offset..][0..8], ticks, .little);
    std.mem.writeInt(u64, bytes[touchscreen_offset + 8 ..][0..8], @min(sample, sample_count), .little);
    std.mem.writeInt(u64, bytes[touchscreen_offset + 16 ..][0..8], index, .little);
    std.mem.writeInt(u64, bytes[touchscreen_offset + 24 ..][0..8], sample_count - 1, .little);
    std.mem.writeInt(u64, bytes[touchscreen_offset + 32 ..][0..8], sample, .little);
}

test "HID tick conversion handles one second and maximal elapsed time" {
    const bytes = try std.testing.allocator.alloc(u8, shared_memory_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    try writeSample(bytes, 1, 1_000_000_000, .{ .buttons = 0, .left_x = 0, .left_y = 0 });
    const layout = controller_offset + 0x28;
    try std.testing.expectEqual(@as(u64, 19_200_000), std.mem.readInt(u64, bytes[layout..][0..8], .little));
    try writeSample(bytes, 2, std.math.maxInt(u64), .{ .buttons = 0, .left_x = 0, .left_y = 0 });
    try std.testing.expectEqual(@as(u64, 354_177_486_215_223_391), std.mem.readInt(u64, bytes[layout..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, bytes[layout + 16 ..][0..8], .little));
}

test "HID rejects undersized shared memory before modifying it" {
    var bytes: [32]u8 = @splat(0x55);
    try std.testing.expectError(error.InvalidSharedMemory, writeSample(&bytes, 1, 0, .{ .buttons = 1, .left_x = 0, .left_y = 0 }));
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0x55))), &bytes);
}

test "right stick axes occupy distinct signed fields and release to zero" {
    const bytes = try std.testing.allocator.alloc(u8, shared_memory_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    try writeSample(bytes, 1, 0, .{ .buttons = 0, .left_x = 10, .left_y = 20, .right_x = 40000, .right_y = -40000 });
    const entry = controller_offset + 0x28 + 0x20 + 0x30;
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, bytes[entry + 24 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 32767), std.mem.readInt(i32, bytes[entry + 32 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, -32767), std.mem.readInt(i32, bytes[entry + 36 ..][0..4], .little));
    try writeSample(bytes, 2, 0, .{ .buttons = 0, .left_x = 0, .left_y = 0 });
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, bytes[entry + 0x30 + 32 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, bytes[entry + 0x30 + 36 ..][0..4], .little));
}

test "legacy touchscreen publishes one contact and a newer release" {
    const bytes = try std.testing.allocator.alloc(u8, shared_memory_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    try writeSample(bytes, 1, 1_000_000_000, .{
        .buttons = 1,
        .left_x = 0,
        .left_y = 0,
        .right_x = 123,
        .touch = .{ .x = 960, .y = 180 },
    });
    try std.testing.expectEqual(@as(u64, 19_200_000), std.mem.readInt(u64, bytes[0x400..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[0x408..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 16), std.mem.readInt(u64, bytes[0x418..][0..8], .little));
    const index = std.mem.readInt(u64, bytes[0x410..][0..8], .little);
    const contact_entry: usize = 0x428 + @as(usize, @intCast(index)) * 0x298;
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[contact_entry..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[contact_entry + 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[contact_entry + 0x1c ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 960), std.mem.readInt(u32, bytes[contact_entry + 0x20 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 180), std.mem.readInt(u32, bytes[contact_entry + 0x24 ..][0..4], .little));
    const controller_entry = controller_offset + 0x1408 + 0x20 + 0x30;
    try std.testing.expectEqual(@as(i32, 123), std.mem.readInt(i32, bytes[controller_entry + 32 ..][0..4], .little));
    try writeSample(bytes, 2, 1_000_000_001, .{ .buttons = 0, .left_x = 0, .left_y = 0 });
    const release_index = std.mem.readInt(u64, bytes[0x410..][0..8], .little);
    const release_entry: usize = 0x428 + @as(usize, @intCast(release_index)) * 0x298;
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, bytes[release_entry..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, bytes[release_entry + 8 ..][0..8], .little));
}

test "touchscreen ring wraps, clamps coordinates, and clears recycled contacts" {
    const bytes = try std.testing.allocator.alloc(u8, shared_memory_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    try writeSample(bytes, 17, 0, .{
        .buttons = 0,
        .left_x = 0,
        .left_y = 0,
        .touch = .{ .x = std.math.maxInt(u32), .y = std.math.maxInt(u32) },
    });
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, bytes[0x410..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 17), std.mem.readInt(u64, bytes[0x408..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 1279), std.mem.readInt(u32, bytes[0x448..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 719), std.mem.readInt(u32, bytes[0x44c..][0..4], .little));
    try writeSample(bytes, 34, 0, .{ .buttons = 0, .left_x = 0, .left_y = 0 });
    try std.testing.expectEqual(@as(u64, 34), std.mem.readInt(u64, bytes[0x428..][0..8], .little));
    try std.testing.expectEqualSlices(u8, &(@as([touch_entry_size - 8]u8, @splat(0))), bytes[0x430..][0 .. touch_entry_size - 8]);
    try std.testing.expectEqual(@as(u8, 0), bytes[0x400 + 0x28 + 17 * 0x298]);
}
