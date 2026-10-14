const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and x < self.x + @as(i32, @intCast(self.width)) and y < self.y + @as(i32, @intCast(self.height));
    }
};

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Canvas {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
    }
    pub fn resize(self: *Canvas, width: u32, height: u32) !void {
        if (width == self.width and height == self.height) return;
        const count = try std.math.mul(usize, width, height);
        if (count > 64 * 1024 * 1024) return error.CanvasTooLarge;
        const pixels = try self.allocator.alloc(u32, count);
        self.allocator.free(self.pixels);
        self.pixels = pixels;
        self.width = width;
        self.height = height;
    }
    pub fn clear(self: *Canvas, color: u32) void {
        @memset(self.pixels, color);
    }
    pub fn rectangle(self: *Canvas, bounds: Rect, color: u32) void {
        const left: usize = @intCast(std.math.clamp(bounds.x, 0, @as(i32, @intCast(self.width))));
        const top: usize = @intCast(std.math.clamp(bounds.y, 0, @as(i32, @intCast(self.height))));
        const right: usize = @intCast(std.math.clamp(@as(i64, bounds.x) + bounds.width, 0, @as(i64, self.width)));
        const bottom: usize = @intCast(std.math.clamp(@as(i64, bounds.y) + bounds.height, 0, @as(i64, self.height)));
        if (right <= left or bottom <= top) return;
        for (top..bottom) |y| @memset(self.pixels[y * self.width + left .. y * self.width + right], color);
    }
    pub fn rounded(self: *Canvas, bounds: Rect, radius: u32, color: u32) void {
        const r = @min(radius, @min(bounds.width, bounds.height) / 2);
        self.rectangle(.{ .x = bounds.x + @as(i32, @intCast(r)), .y = bounds.y, .width = bounds.width - 2 * r, .height = bounds.height }, color);
        for (0..bounds.height) |y| {
            const dy: i64 = if (y < r) @as(i64, r) - @as(i64, @intCast(y)) - 1 else if (y >= bounds.height - r) @as(i64, @intCast(y)) - (bounds.height - r) else 0;
            const inset: u32 = if (dy == 0) 0 else @intCast(r - @as(u32, @intFromFloat(@sqrt(@as(f64, @floatFromInt(@as(i64, r) * r - dy * dy))))));
            self.rectangle(.{ .x = bounds.x + @as(i32, @intCast(inset)), .y = bounds.y + @as(i32, @intCast(y)), .width = bounds.width - 2 * inset, .height = 1 }, color);
        }
    }
    pub fn text(self: *Canvas, x: i32, y: i32, value: []const u8, scale: u32, color: u32) void {
        var xx = x;
        var yy = y;
        for (value) |byte| {
            if (byte == '\n') {
                xx = x;
                yy += @intCast(10 * scale);
                continue;
            }
            const rows = glyph(std.ascii.toUpper(byte));
            for (rows, 0..) |bits, row| for (0..5) |column| {
                if (bits & (@as(u8, 16) >> @intCast(column)) != 0) self.rectangle(.{
                    .x = xx + @as(i32, @intCast(column * scale)),
                    .y = yy + @as(i32, @intCast(row * scale)),
                    .width = scale,
                    .height = scale,
                }, color);
            };
            xx += @intCast(6 * scale);
            if (xx >= self.width) break;
        }
    }
    pub fn image(self: *Canvas, pixels: []const u32, width: u32, height: u32, bounds: Rect) void {
        if (width == 0 or height == 0 or bounds.width == 0 or bounds.height == 0) return;
        for (0..bounds.height) |y| {
            const yy = @as(i64, bounds.y) + @as(i64, @intCast(y));
            if (yy < 0 or yy >= self.height) continue;
            for (0..bounds.width) |x| {
                const xx = @as(i64, bounds.x) + @as(i64, @intCast(x));
                if (xx < 0 or xx >= self.width) continue;
                self.pixels[@as(usize, @intCast(yy)) * self.width + @as(usize, @intCast(xx))] = pixels[(y * height / bounds.height) * width + x * width / bounds.width];
            }
        }
    }
};

fn glyph(character: u8) [7]u8 {
    return switch (character) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 15 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
        'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        '.' => .{ 0, 0, 0, 0, 0, 6, 6 },
        ':' => .{ 0, 6, 6, 0, 6, 6, 0 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
        '/' => .{ 1, 2, 2, 4, 8, 8, 16 },
        '(' => .{ 2, 4, 8, 8, 8, 4, 2 },
        ')' => .{ 8, 4, 2, 2, 2, 4, 8 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 31 },
        '>' => .{ 16, 8, 4, 2, 4, 8, 16 },
        '=' => .{ 0, 0, 31, 0, 31, 0, 0 },
        '!' => .{ 4, 4, 4, 4, 4, 0, 4 },
        ',' => .{ 0, 0, 0, 0, 0, 4, 8 },
        ' ' => @splat(0),
        else => .{ 14, 17, 1, 2, 4, 0, 4 },
    };
}

pub fn writePng(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bgra: []const u8, width: u32, height: u32) !void {
    if (bgra.len != @as(usize, width) * height * 4) return error.InvalidScreenshot;
    const row_size = @as(usize, width) * 3 + 1;
    const raw = try allocator.alloc(u8, row_size * height);
    defer allocator.free(raw);
    for (0..height) |y| {
        raw[y * row_size] = 0;
        for (0..width) |x| {
            const input = (y * width + x) * 4;
            const output = y * row_size + x * 3 + 1;
            raw[output] = bgra[input + 2];
            raw[output + 1] = bgra[input + 1];
            raw[output + 2] = bgra[input];
        }
    }
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    try compressed.appendSlice(allocator, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < raw.len) {
        const length: u16 = @intCast(@min(raw.len - offset, 65535));
        var header: [5]u8 = undefined;
        header[0] = if (offset + length == raw.len) 1 else 0;
        std.mem.writeInt(u16, header[1..3], length, .little);
        std.mem.writeInt(u16, header[3..5], ~length, .little);
        try compressed.appendSlice(allocator, &header);
        try compressed.appendSlice(allocator, raw[offset..][0..length]);
        offset += length;
    }
    var a: u32 = 1;
    var b: u32 = 0;
    for (raw) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, (b << 16) | a, .big);
    try compressed.appendSlice(allocator, &checksum);
    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(allocator);
    try png.appendSlice(allocator, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8;
    header[9] = 2;
    try chunk(&png, allocator, "IHDR", &header);
    try chunk(&png, allocator, "IDAT", compressed.items);
    try chunk(&png, allocator, "IEND", &.{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png.items });
}

fn chunk(png: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: *const [4]u8, bytes: []const u8) !void {
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, @intCast(bytes.len), .big);
    try png.appendSlice(allocator, &number);
    const start = png.items.len;
    try png.appendSlice(allocator, kind);
    try png.appendSlice(allocator, bytes);
    std.mem.writeInt(u32, &number, std.hash.Crc32.hash(png.items[start..]), .big);
    try png.appendSlice(allocator, &number);
}
