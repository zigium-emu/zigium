const std = @import("std");

pub const shared_memory_size: usize = 0x40000;
pub const controller_offset: usize = 0x9a00;
pub const layout_size: usize = 0x350;
pub const sample_count: usize = 17;
pub const Input = struct { buttons: u64, left_x: i32, left_y: i32 };

pub fn writeSample(bytes: []u8, sample: u64, elapsed_ns: u64, input: Input) !void {
    if (bytes.len != shared_memory_size) return error.InvalidSharedMemory;
    const index: usize = @intCast(sample % sample_count);
    const ticks: u64 = @intCast(@min((@as(u128, elapsed_ns) * 19_200_000) / 1_000_000_000, std.math.maxInt(u64)));
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
        std.mem.writeInt(i32, bytes[entry + 32 ..][0..4], 0, .little);
        std.mem.writeInt(i32, bytes[entry + 36 ..][0..4], 0, .little);
        std.mem.writeInt(u64, bytes[entry + 40 ..][0..8], 3, .little);
    }
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
