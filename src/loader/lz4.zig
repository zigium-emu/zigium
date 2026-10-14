const std = @import("std");

fn length(input: []const u8, cursor: *usize, nibble: u8) !usize {
    var result: usize = nibble;
    if (nibble != 15) return result;
    while (true) {
        if (cursor.* == input.len) return error.TruncatedLz4;
        const extra = input[cursor.*];
        cursor.* += 1;
        result = std.math.add(usize, result, extra) catch return error.MalformedLz4;
        if (extra != 255) return result;
    }
}

pub fn decompress(input: []const u8, output: []u8) !void {
    var source: usize = 0;
    var destination: usize = 0;
    var last_match: ?usize = null;
    while (true) {
        if (source == input.len) return error.TruncatedLz4;
        const token = input[source];
        source += 1;
        const literals = try length(input, &source, token >> 4);
        if (literals > input.len - source) return error.TruncatedLz4;
        if (literals > output.len - destination) return error.Lz4OutputSize;
        @memcpy(output[destination..][0..literals], input[source..][0..literals]);
        source += literals;
        destination += literals;
        if (source == input.len) {
            if (destination != output.len) return error.Lz4OutputSize;
            if (last_match) |start| {
                if (literals < 5 or output.len - start < 12) return error.MalformedLz4;
            }
            return;
        }
        if (input.len - source < 2) return error.TruncatedLz4;
        const offset = std.mem.readInt(u16, input[source..][0..2], .little);
        source += 2;
        if (offset == 0 or offset > destination) return error.InvalidLz4Offset;
        const match_length = std.math.add(usize, try length(input, &source, token & 15), 4) catch return error.MalformedLz4;
        if (match_length > output.len - destination) return error.Lz4OutputSize;
        last_match = destination;
        // LZ4 matches can overlap and reuse bytes emitted by the same match.
        for (0..match_length) |_| {
            output[destination] = output[destination - offset];
            destination += 1;
        }
    }
}

test "LZ4 literal-only block, extended literal length and empty block" {
    var empty: [0]u8 = .{};
    try decompress(&.{0}, &empty);
    var output: [5]u8 = undefined;
    try decompress(&.{ 0x50, 'h', 'e', 'l', 'l', 'o' }, &output);
    try std.testing.expectEqualStrings("hello", &output);
    var long_input: [273]u8 = @splat('x');
    long_input[0] = 0xf0;
    long_input[1] = 255;
    long_input[2] = 0;
    var long_output: [270]u8 = undefined;
    try decompress(&long_input, &long_output);
    for (long_output) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
}

test "LZ4 overlapping matches and extended match length" {
    var output: [17]u8 = undefined;
    try decompress(&.{ 0x35, 'a', 'b', 'c', 3, 0, 0x50, 't', 'a', 'i', 'l', '!' }, &output);
    try std.testing.expectEqualStrings("abcabcabcabctail!", &output);
    var long_output: [25]u8 = undefined;
    try decompress(&.{ 0x1f, 'a', 1, 0, 0, 0x50, 't', 'a', 'i', 'l', '!' }, &long_output);
    for (long_output[0..20]) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
    try std.testing.expectEqualStrings("tail!", long_output[20..]);
}

test "LZ4 rejects truncated lengths, invalid offsets and wrong output size" {
    var output: [20]u8 = undefined;
    try std.testing.expectError(error.TruncatedLz4, decompress(&.{}, &output));
    try std.testing.expectError(error.TruncatedLz4, decompress(&.{ 0xf0, 255 }, &output));
    try std.testing.expectError(error.TruncatedLz4, decompress(&.{ 0x50, 'a' }, &output));
    try std.testing.expectError(error.InvalidLz4Offset, decompress(&.{ 0x10, 'a', 0, 0 }, &output));
    try std.testing.expectError(error.InvalidLz4Offset, decompress(&.{ 0x10, 'a', 2, 0 }, &output));
    try std.testing.expectError(error.Lz4OutputSize, decompress(&.{ 0x50, 'h', 'e', 'l', 'l', 'o' }, output[0..4]));
    try std.testing.expectError(error.Lz4OutputSize, decompress(&.{ 0x50, 'h', 'e', 'l', 'l', 'o' }, output[0..6]));
    try std.testing.expectError(error.TruncatedLz4, decompress(&.{ 0x10, 'a', 1, 0 }, output[0..5]));
}
