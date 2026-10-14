const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;

pub const base: u64 = 0x7100000000;
pub const page_size: u64 = 0x1000;
/// An explicit host resource limit, independent of the guest format's u32 fields.
pub const max_image_size: u64 = 256 * 1024 * 1024;

pub const Loaded = struct {
    entry: u64,
    base: u64,
    image_size: u64,
};

const Segment = struct {
    offset: u64,
    size: u64,

    fn end(self: Segment) u64 {
        return self.offset + self.size;
    }
};

const Header = struct {
    segments: [3]Segment,
    bss_size: u64,
    file_size: u64,
    mapped_size: u64,
};

fn integer(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn pageAligned(value: u64) bool {
    return value & (page_size - 1) == 0;
}

fn validateAssets(bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (bytes.len < 0x38 or !std.mem.eql(u8, bytes[0..4], "ASET")) return error.MalformedAssets;
    if (integer(u32, bytes, 4) != 0) return error.UnsupportedAssetVersion;
    var ranges: [3]Segment = undefined;
    for (&ranges, 0..) |*range, i| {
        range.* = .{
            .offset = integer(u64, bytes, 8 + i * 16),
            .size = integer(u64, bytes, 16 + i * 16),
        };
        if (range.size == 0) continue;
        const end = std.math.add(u64, range.offset, range.size) catch return error.MalformedAssets;
        if (range.offset < 0x38 or end > bytes.len) return error.MalformedAssets;
        for (ranges[0..i]) |earlier| {
            if (earlier.size != 0 and range.offset < earlier.end() and earlier.offset < end)
                return error.OverlappingAssets;
        }
    }
}

fn parse(bytes: []const u8) !Header {
    if (bytes.len < 0x80) return error.TruncatedNro;
    if (!std.mem.eql(u8, bytes[0x10..0x14], "NRO0")) return error.InvalidNroMagic;
    if (integer(u32, bytes, 0x14) != 0) return error.UnsupportedNroVersion;
    if (integer(u32, bytes, 0x1c) & ~@as(u32, 1) != 0) return error.UnsupportedNroFlags;
    var header: Header = .{
        .segments = undefined,
        .bss_size = integer(u32, bytes, 0x38),
        .file_size = integer(u32, bytes, 0x18),
        .mapped_size = 0,
    };
    if (header.file_size < 0x80 or header.file_size > bytes.len) return error.TruncatedNro;
    if (!pageAligned(header.file_size)) return error.UnalignedNro;
    for (&header.segments, 0..) |*segment, i| {
        segment.* = .{
            .offset = integer(u32, bytes, 0x20 + i * 8),
            .size = integer(u32, bytes, 0x24 + i * 8),
        };
        if (!pageAligned(segment.offset) or !pageAligned(segment.size)) return error.UnalignedNro;
        if (segment.end() > header.file_size) return error.SegmentOutsideNro;
        if (i != 0 and segment.offset < header.segments[i - 1].end()) return error.OverlappingSegments;
    }
    if (header.segments[0].offset != 0 or header.segments[0].size < 0x80) return error.InvalidTextSegment;
    if (header.segments[2].end() != header.file_size) return error.InvalidDataSegment;
    const total = header.file_size + header.bss_size;
    header.mapped_size = (total + page_size - 1) & ~(page_size - 1);
    if (header.mapped_size > max_image_size) return error.ImageTooLarge;
    _ = std.math.add(u64, base, header.mapped_size) catch return error.AddressOverflow;
    try validateAssets(bytes[@intCast(header.file_size)..]);
    return header;
}

/// All validation precedes mutation; failed loads remove their own mappings.
pub fn load(memory: *Memory, bytes: []const u8) !Loaded {
    const header = try parse(bytes);
    var mapped: [3]Segment = undefined;
    var mapped_count: usize = 0;
    errdefer for (mapped[0..mapped_count]) |segment| {
        memory.unmap(base + segment.offset, @intCast(segment.size)) catch {};
    };
    for (header.segments, 0..) |segment, i| {
        const mapped_length = segment.size + if (i == 2)
            header.mapped_size - header.file_size
        else
            @as(u64, 0);
        if (mapped_length == 0) continue;
        const address = base + segment.offset;
        try memory.mapWithState(address, @intCast(mapped_length), .{ .read = true, .write = true, .execute = false }, if (i == 2) 9 else 8);
        mapped[mapped_count] = .{ .offset = segment.offset, .size = mapped_length };
        mapped_count += 1;
        const start: usize = @intCast(segment.offset);
        const end: usize = @intCast(segment.end());
        try memory.write(address, bytes[start..end]);
        if (i != 2) try memory.protect(address, @intCast(mapped_length), .{
            .read = true,
            .write = false,
            .execute = i == 0,
        });
    }
    return .{ .entry = base, .base = base, .image_size = header.mapped_size };
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn fixture() [0x3000]u8 {
    var bytes: [0x3000]u8 = @splat(0);
    put(u32, &bytes, 0, 0x14000020); // B +0x80, the actual entry instruction.
    @memcpy(bytes[0x10..0x14], "NRO0");
    put(u32, &bytes, 0x18, bytes.len);
    put(u32, &bytes, 0x20, 0);
    put(u32, &bytes, 0x24, 0x1000);
    put(u32, &bytes, 0x28, 0x1000);
    put(u32, &bytes, 0x2c, 0x1000);
    put(u32, &bytes, 0x30, 0x2000);
    put(u32, &bytes, 0x34, 0x1000);
    put(u32, &bytes, 0x38, 17);
    bytes[0x1000] = 0x42;
    bytes[0x2000] = 0x73;
    return bytes;
}

test "NRO entry, contents, zero BSS and segment write permissions" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    const bytes = fixture();
    const loaded = try load(&memory, &bytes);
    try std.testing.expectEqual(base, loaded.entry);
    try std.testing.expectEqual(@as(u64, 0x4000), loaded.image_size);
    try std.testing.expectEqual(@as(u32, 0x14000020), try memory.readInt(u32, base));
    try std.testing.expectEqual(@as(u32, 0x14000020), try memory.fetch(base));
    try std.testing.expectEqual(@as(u32, 8), (try memory.query(base)).state);
    try std.testing.expectEqual(@as(u32, 9), (try memory.query(base + 0x2000)).state);
    try std.testing.expectError(error.AccessDenied, memory.fetch(base + 0x1000));
    try std.testing.expectError(error.AccessDenied, memory.fetch(base + 0x2000));
    try std.testing.expectEqual(@as(u8, 0x42), try memory.readInt(u8, base + 0x1000));
    try std.testing.expectEqual(@as(u8, 0x73), try memory.readInt(u8, base + 0x2000));
    try std.testing.expectEqual(@as(u64, 0), try memory.readInt(u64, base + 0x3000));
    try std.testing.expectEqual(@as(u8, 0), try memory.readInt(u8, base + 0x3fff));
    try memory.writeInt(u64, base + 0x3000, 0x1234);
    const text_denied = if (memory.writeInt(u8, base, 0)) |_| false else |_| true;
    const ro_denied = if (memory.writeInt(u8, base + 0x1000, 0)) |_| false else |_| true;
    try std.testing.expect(text_denied and ro_denied);
}

test "NRO rejects truncated, overlapping, out of bounds and unaligned segments" {
    var bytes = fixture();
    try std.testing.expectError(error.TruncatedNro, parse(bytes[0..0x7f]));
    try std.testing.expectError(error.TruncatedNro, parse(bytes[0..0x2000]));
    put(u32, &bytes, 0x28, 0);
    try std.testing.expectError(error.OverlappingSegments, parse(&bytes));
    bytes = fixture();
    put(u32, &bytes, 0x34, 0xfffff000);
    try std.testing.expectError(error.SegmentOutsideNro, parse(&bytes));
    bytes = fixture();
    put(u32, &bytes, 0x28, 0x1001);
    try std.testing.expectError(error.UnalignedNro, parse(&bytes));
    bytes = fixture();
    put(u32, &bytes, 0x38, 0xffffffff);
    try std.testing.expectError(error.ImageTooLarge, parse(&bytes));
}

test "NRO accepts bounded ASET sections and rejects malformed trailers" {
    const image = fixture();
    var bytes: [0x3040]u8 = @splat(0);
    @memcpy(bytes[0..image.len], &image);
    @memcpy(bytes[0x3000..0x3004], "ASET");
    put(u64, &bytes, 0x3008, 0x38);
    put(u64, &bytes, 0x3010, 8);
    _ = try parse(&bytes);
    put(u64, &bytes, 0x3010, 9);
    try std.testing.expectError(error.MalformedAssets, parse(&bytes));
    put(u64, &bytes, 0x3010, 8);
    put(u64, &bytes, 0x3018, 0x38);
    put(u64, &bytes, 0x3020, 1);
    try std.testing.expectError(error.OverlappingAssets, parse(&bytes));
    put(u64, &bytes, 0x3018, std.math.maxInt(u64));
    try std.testing.expectError(error.MalformedAssets, parse(&bytes));
    try std.testing.expectError(error.MalformedAssets, parse(bytes[0..0x3020]));
}

test "failed NRO mapping rolls back and preserves preexisting memory" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(base + 0x1000, 0x1000, .{ .read = true, .write = true });
    try memory.writeInt(u32, base + 0x1000, 0x55);
    const bytes = fixture();
    try std.testing.expectError(error.OverlappingMapping, load(&memory, &bytes));
    try std.testing.expectEqual(@as(u32, 0), (try memory.query(base)).state);
    try std.testing.expectEqual(@as(u32, 0x55), try memory.readInt(u32, base + 0x1000));
}
