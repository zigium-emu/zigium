const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;

pub const Layout = struct {
    address: u64,
    byte_length: usize,
    width: u32,
    height: u32,
    stride: u32,
    block_height_log2: u3 = 4,
    block_linear: bool = true,
    flip_h: bool = false,
    flip_v: bool = false,
};

pub fn byteOffset(x: u32, y: u32, stride: u32, block_height_log2: u3) usize {
    const block_height: usize = @as(usize, 1) << block_height_log2;
    const block_shift: u6 = @as(u6, block_height_log2) + 3;
    const width_gobs = (@as(usize, stride) * 4 + 63) / 64;
    const xb: usize = @as(usize, x) * 4;
    const yy: usize = y;
    const gob = (yy >> block_shift) * 512 * block_height * width_gobs +
        (xb / 64) * 512 * block_height + ((yy & ((@as(usize, 1) << block_shift) - 1)) / 8) * 512;
    return gob + ((xb % 64) / 32) * 256 + ((yy % 8) / 2) * 64 + ((xb % 32) / 16) * 32 + (yy % 2) * 16 + xb % 16;
}

pub fn decode(memory: *const Memory, allocator: std.mem.Allocator, layout: Layout, output: []u32) !void {
    if (layout.width == 0 or layout.height == 0 or layout.width > 4096 or layout.height > 4096 or layout.stride < layout.width or layout.stride > 4096 or layout.byte_length > 128 * 1024 * 1024) return error.InvalidFramebuffer;
    const count = @as(usize, layout.width) * layout.height;
    if (output.len != count) return error.InvalidFramebuffer;
    const bytes = try allocator.alloc(u8, layout.byte_length);
    defer allocator.free(bytes);
    try memory.read(layout.address, bytes);
    for (0..layout.height) |y| {
        for (0..layout.width) |x| {
            const sx: u32 = @intCast(if (layout.flip_h) layout.width - 1 - x else x);
            const sy: u32 = @intCast(if (layout.flip_v) layout.height - 1 - y else y);
            const offset = if (layout.block_linear) byteOffset(sx, sy, layout.stride, layout.block_height_log2) else (@as(usize, sy) * layout.stride + sx) * 4;
            if (offset > bytes.len or bytes.len - offset < 4) return error.InvalidFramebuffer;
            output[y * layout.width + x] = 0xff000000 | (@as(u32, bytes[offset]) << 16) | (@as(u32, bytes[offset + 1]) << 8) | bytes[offset + 2];
        }
    }
}

test "Tegra GOB ordering at row and 16-byte boundaries" {
    try std.testing.expectEqual(@as(usize, 0), byteOffset(0, 0, 32, 0));
    try std.testing.expectEqual(@as(usize, 16), byteOffset(0, 1, 32, 0));
    try std.testing.expectEqual(@as(usize, 32), byteOffset(4, 0, 32, 0));
    try std.testing.expectEqual(@as(usize, 64), byteOffset(0, 2, 32, 0));
    try std.testing.expectEqual(@as(usize, 256), byteOffset(8, 0, 32, 0));
    try std.testing.expectEqual(@as(usize, 512), byteOffset(16, 0, 32, 0));
    try std.testing.expectEqual(@as(usize, 1024), byteOffset(0, 8, 32, 0));
    try std.testing.expectEqual(@as(usize, 512), byteOffset(0, 8, 32, 1));
    try std.testing.expectEqual(@as(usize, 1024), byteOffset(16, 0, 32, 1));
}

test "frame decoding respects RGBA order, stride and queue flips" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    try memory.write(0x1000, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 });
    var pixels: [4]u32 = undefined;
    try decode(&memory, std.testing.allocator, .{ .address = 0x1000, .byte_length = 16, .width = 2, .height = 2, .stride = 2, .block_linear = false, .flip_v = true }, &pixels);
    try std.testing.expectEqualSlices(u32, &.{ 0xff0000ff, 0xffffffff, 0xffff0000, 0xff00ff00 }, &pixels);
    try std.testing.expectError(error.InvalidFramebuffer, decode(&memory, std.testing.allocator, .{ .address = 0x1000, .byte_length = 4, .width = 2, .height = 2, .stride = 2, .block_linear = false }, &pixels));
}
