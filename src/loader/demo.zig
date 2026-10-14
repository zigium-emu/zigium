const std = @import("std");

pub const message = "Hello from Zigium homebrew!\n";

pub fn hello(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, 0x3000);
    @memset(bytes, 0);
    put(bytes, 0, 0x14000020);
    @memcpy(bytes[0x10..0x14], "NRO0");
    put(bytes, 0x18, @intCast(bytes.len));
    for (0..3) |i| {
        put(bytes, 0x20 + i * 8, @intCast(i * 0x1000));
        put(bytes, 0x24 + i * 8, 0x1000);
    }
    put(bytes, 0x38, 0x1000);
    const instructions = [_]u32{
        0x10007c00,
        0xd2800001 | (@as(u32, message.len) << 5),
        0xd40004e1,
        0xd2800000,
        0xd40000e1,
        0x14000000,
    };
    for (instructions, 0..) |instruction, i| put(bytes, 0x80 + i * 4, instruction);
    @memcpy(bytes[0x1000..][0..message.len], message);
    return bytes;
}

fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
