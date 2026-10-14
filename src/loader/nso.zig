const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;
const nro = @import("nro.zig");
const lz4 = @import("lz4.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Loaded = nro.Loaded;
pub const base = nro.base;

const Segment = struct {
    file_offset: u64,
    file_size: u64,
    offset: u64,
    size: u64,
    mapped_size: u64,
    compressed: bool,
    hash_checked: bool,
    hash: [32]u8,
};

const Header = struct {
    segments: [3]Segment,
    image_size: u64,
    execute_only: bool,
};

fn integer(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn parse(bytes: []const u8) !Header {
    if (bytes.len < 0x100) return error.TruncatedNso;
    if (!std.mem.eql(u8, bytes[0..4], "NSO0")) return error.InvalidNsoMagic;
    if (integer(u32, bytes, 4) != 0) return error.UnsupportedNsoVersion;
    const flags = integer(u32, bytes, 0xc);
    if (flags & 0x80 != 0) return error.UnsupportedNsoCompression;
    if (flags & ~@as(u32, 0x7f) != 0) return error.UnsupportedNsoFlags;
    const bss_size: u64 = integer(u32, bytes, 0x3c);
    var header: Header = .{ .segments = undefined, .image_size = 0, .execute_only = flags & 0x40 != 0 };
    for (&header.segments, 0..) |*segment, i| {
        const compressed = flags & (@as(u32, 1) << @intCast(i)) != 0;
        const size: u64 = integer(u32, bytes, 0x18 + i * 16);
        const mapped_size = size + if (i == 2) bss_size else @as(u64, 0);
        segment.* = .{
            .file_offset = integer(u32, bytes, 0x10 + i * 16),
            .file_size = if (compressed) integer(u32, bytes, 0x60 + i * 4) else size,
            .offset = integer(u32, bytes, 0x14 + i * 16),
            .size = size,
            .mapped_size = (mapped_size + nro.page_size - 1) & ~(nro.page_size - 1),
            .compressed = compressed,
            .hash_checked = flags & (@as(u32, 8) << @intCast(i)) != 0,
            .hash = bytes[0xa0 + i * 32 ..][0..32].*,
        };
        if (segment.offset & (nro.page_size - 1) != 0) return error.UnalignedNso;
        if (segment.file_size != 0 and segment.file_offset < 0x100) return error.SegmentOutsideNso;
        if (segment.file_offset + segment.file_size > bytes.len) return error.SegmentOutsideNso;
        if (segment.offset + segment.mapped_size > nro.max_image_size) return error.ImageTooLarge;
        for (header.segments[0..i]) |earlier| {
            if (segment.file_size != 0 and earlier.file_size != 0 and
                segment.file_offset < earlier.file_offset + earlier.file_size and
                earlier.file_offset < segment.file_offset + segment.file_size) return error.OverlappingNsoFiles;
        }
        if (i != 0 and segment.offset < header.segments[i - 1].offset + header.segments[i - 1].mapped_size)
            return error.OverlappingNsoSegments;
        header.image_size = @max(header.image_size, segment.offset + segment.mapped_size);
    }
    if (header.segments[0].offset != 0 or header.segments[0].size < 4) return error.InvalidTextSegment;
    return header;
}

/// Failed loads remove their own mappings, including on decompression/hash errors.
pub fn load(memory: *Memory, bytes: []const u8) !Loaded {
    const header = try parse(bytes);
    var mapped_count: usize = 0;
    errdefer for (header.segments[0..mapped_count]) |segment| {
        if (segment.mapped_size != 0) memory.unmap(base + segment.offset, @intCast(segment.mapped_size)) catch {};
    };
    for (header.segments, 0..) |segment, i| {
        const source = bytes[@intCast(segment.file_offset)..][0..@intCast(segment.file_size)];
        const decoded = if (segment.compressed) try memory.allocator.alloc(u8, @intCast(segment.size)) else null;
        defer if (decoded) |output| memory.allocator.free(output);
        const contents: []const u8 = if (decoded) |output| decoded_contents: {
            try lz4.decompress(source, output);
            break :decoded_contents output;
        } else source;
        if (segment.hash_checked) {
            var digest: [32]u8 = undefined;
            Sha256.hash(contents, &digest, .{});
            if (!std.mem.eql(u8, &digest, &segment.hash)) return error.NsoHashMismatch;
        }
        if (segment.mapped_size != 0) {
            const address = base + segment.offset;
            try memory.mapWithState(address, @intCast(segment.mapped_size), .{ .read = true, .write = true }, if (i == 2) 4 else 3);
            mapped_count = i + 1;
            try memory.write(address, contents);
            if (i != 2) try memory.protect(address, @intCast(segment.mapped_size), .{
                .read = i != 0 or !header.execute_only,
                .execute = i == 0,
            });
        } else {
            mapped_count = i + 1;
        }
    }
    return .{ .entry = base, .base = base, .image_size = header.image_size };
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn fixture(compressed: bool) [0x140]u8 {
    var bytes: [0x140]u8 = @splat(0);
    @memcpy(bytes[0..4], "NSO0");
    put(u32, &bytes, 0xc, if (compressed) 0x3f else 0x38);
    put(u32, &bytes, 0x3c, 37);
    const text = [_]u8{ 0x1f, 0x20, 0x03, 0xd5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const contents = [_][]const u8{ &text, "readonlydata", "hello" };
    var offset: usize = 0x100;
    for (contents, 0..) |content, i| {
        put(u32, &bytes, 0x10 + i * 16, @intCast(offset));
        put(u32, &bytes, 0x14 + i * 16, @intCast(i * 0x1000));
        put(u32, &bytes, 0x18 + i * 16, @intCast(content.len));
        var digest: [32]u8 = undefined;
        Sha256.hash(content, &digest, .{});
        @memcpy(bytes[0xa0 + i * 32 ..][0..32], &digest);
        const start = offset;
        if (compressed) {
            bytes[offset] = @as(u8, @intCast(@min(content.len, 15))) << 4;
            offset += 1;
            if (content.len >= 15) {
                bytes[offset] = @intCast(content.len - 15);
                offset += 1;
            }
        }
        @memcpy(bytes[offset..][0..content.len], content);
        offset += content.len;
        put(u32, &bytes, 0x60 + i * 4, @intCast(offset - start));
    }
    return bytes;
}

test "NSO raw and LZ4 images verify hashes and map BSS and permissions" {
    for ([_]bool{ false, true }) |compressed| {
        var memory = Memory.init(std.testing.allocator);
        defer memory.deinit();
        const bytes = fixture(compressed);
        const loaded = try load(&memory, &bytes);
        try std.testing.expectEqual(base, loaded.entry);
        try std.testing.expectEqual(@as(u64, 0x3000), loaded.image_size);
        try std.testing.expectEqual(@as(u32, 0xd503201f), try memory.fetch(base));
        try std.testing.expectEqual(@as(u32, 3), (try memory.query(base)).state);
        try std.testing.expectEqual(@as(u32, 4), (try memory.query(base + 0x2000)).state);
        try std.testing.expectEqual(@as(u8, 'h'), try memory.readInt(u8, base + 0x2000));
        try std.testing.expectEqual(@as(u64, 0), try memory.readInt(u64, base + 0x2005));
        try std.testing.expectError(error.AccessDenied, memory.writeInt(u8, base, 0));
        try std.testing.expectError(error.AccessDenied, memory.fetch(base + 0x1000));
    }
}

test "NSO rejects bad bounds, overlaps, unsupported compression and corrupt hash" {
    var bytes = fixture(false);
    try std.testing.expectError(error.TruncatedNso, parse(bytes[0..0xff]));
    put(u32, &bytes, 0x18, 0xffffffff);
    try std.testing.expectError(error.SegmentOutsideNso, parse(&bytes));
    bytes = fixture(false);
    put(u32, &bytes, 0x24, 0);
    try std.testing.expectError(error.OverlappingNsoSegments, parse(&bytes));
    bytes = fixture(false);
    put(u32, &bytes, 0x20, 0x100);
    try std.testing.expectError(error.OverlappingNsoFiles, parse(&bytes));
    bytes = fixture(false);
    put(u32, &bytes, 0xc, 0x80);
    try std.testing.expectError(error.UnsupportedNsoCompression, parse(&bytes));
    bytes = fixture(false);
    bytes[0x11c] ^= 1;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try std.testing.expectError(error.NsoHashMismatch, load(&memory, &bytes));
    try std.testing.expectEqual(@as(usize, 0), memory.mapped_bytes);
}

test "NSO execute-only text allows instruction fetch and denies reads" {
    var bytes = fixture(false);
    put(u32, &bytes, 0xc, 0x78);
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    _ = try load(&memory, &bytes);
    try std.testing.expectEqual(@as(u32, 0xd503201f), try memory.fetch(base));
    try std.testing.expectError(error.AccessDenied, memory.readInt(u32, base));
}
