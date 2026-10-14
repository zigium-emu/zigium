const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;

pub const message_size = 0x100;
pub const Buffer = struct { address: u64, size: usize };
pub const Request = struct {
    bytes: [message_size]u8,
    message_type: u16,
    command_id: u32 = 0,
    token: u32 = 0,
    domain_object: u32 = 0,
    domain_type: u8 = 0,
    payload_offset: usize = 0,
    payload_end: usize = 0,
    sends: [30]Buffer = undefined,
    receives: [30]Buffer = undefined,
    send_count: usize = 0,
    receive_count: usize = 0,
    copy_handles: [15]u32 = undefined,
    move_handles: [15]u32 = undefined,
    copy_count: usize = 0,
    move_count: usize = 0,
    send_pid: bool = false,

    pub fn integer(self: *const Request, comptime T: type, offset: usize) !T {
        const start = std.math.add(usize, self.payload_offset, offset) catch return error.InvalidIpc;
        if (start > self.payload_end or @sizeOf(T) > self.payload_end - start) return error.InvalidIpc;
        return std.mem.readInt(T, self.bytes[start..][0..@sizeOf(T)], .little);
    }

    pub fn inputBuffer(self: *const Request) ?Buffer {
        for (self.sends[0..self.send_count]) |buffer| if (buffer.size != 0) return buffer;
        return null;
    }

    pub fn outputBuffer(self: *const Request) ?Buffer {
        for (self.receives[0..self.receive_count]) |buffer| if (buffer.size != 0) return buffer;
        return null;
    }
};

pub fn validateRange(memory: *const Memory, address: u64, length: usize, write: bool) !void {
    const end = std.math.add(u64, address, length) catch return error.InvalidIpc;
    var cursor = address;
    while (cursor < end) {
        const region = try memory.query(cursor);
        if (!region.permissions.read or (write and !region.permissions.write)) return error.InvalidIpc;
        const region_end = std.math.add(u64, region.base, region.size) catch return error.InvalidIpc;
        if (region_end <= cursor) return error.InvalidIpc;
        cursor = @min(end, region_end);
    }
}

fn word(bytes: []const u8, offset: usize) !u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.InvalidIpc;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn advance(cursor: *usize, amount: usize) !void {
    cursor.* = std.math.add(usize, cursor.*, amount) catch return error.InvalidIpc;
    if (cursor.* > message_size) return error.InvalidIpc;
}

pub fn parse(memory: *const Memory, address: u64, domain: bool) !Request {
    var request: Request = undefined;
    request = .{ .bytes = undefined, .message_type = 0 };
    try memory.read(address, &request.bytes);
    try validateRange(memory, address, message_size, true);
    const first = try word(&request.bytes, 0);
    const second = try word(&request.bytes, 4);
    request.message_type = @truncate(first);
    const num_statics = (first >> 16) & 15;
    const num_sends = (first >> 20) & 15;
    const num_receives = (first >> 24) & 15;
    const num_exchanges = (first >> 28) & 15;
    const data_words = second & 1023;
    const receive_mode = (second >> 10) & 15;
    var cursor: usize = 8;
    if (second >> 31 != 0) {
        const special = try word(&request.bytes, cursor);
        try advance(&cursor, 4);
        request.send_pid = special & 1 != 0;
        request.copy_count = (special >> 1) & 15;
        request.move_count = (special >> 5) & 15;
        if (request.send_pid) try advance(&cursor, 8);
        for (request.copy_handles[0..request.copy_count]) |*handle| {
            handle.* = try word(&request.bytes, cursor);
            try advance(&cursor, 4);
        }
        for (request.move_handles[0..request.move_count]) |*handle| {
            handle.* = try word(&request.bytes, cursor);
            try advance(&cursor, 4);
        }
    }
    for (0..num_statics) |_| {
        const a = try word(&request.bytes, cursor);
        const b = try word(&request.bytes, cursor + 4);
        const buffer: Buffer = .{ .address = @as(u64, b) | (@as(u64, (a >> 12) & 15) << 32) | (@as(u64, (a >> 6) & 63) << 36), .size = a >> 16 };
        try validateRange(memory, buffer.address, buffer.size, false);
        request.sends[request.send_count] = buffer;
        request.send_count += 1;
        try advance(&cursor, 8);
    }
    for (0..num_sends + num_receives + num_exchanges) |i| {
        const a = try word(&request.bytes, cursor);
        const b = try word(&request.bytes, cursor + 4);
        const c = try word(&request.bytes, cursor + 8);
        if (c & 3 == 2) return error.InvalidIpc;
        const buffer: Buffer = .{ .address = @as(u64, b) | (@as(u64, c >> 28) << 32) | (@as(u64, (c >> 2) & 0x3fffff) << 36), .size = @intCast(@as(u64, a) | (@as(u64, (c >> 24) & 15) << 32)) };
        const is_input = i < num_sends or i >= num_sends + num_receives;
        const is_output = i >= num_sends;
        try validateRange(memory, buffer.address, buffer.size, is_output);
        if (is_input) {
            if (request.send_count == request.sends.len) return error.InvalidIpc;
            request.sends[request.send_count] = buffer;
            request.send_count += 1;
        }
        if (is_output) {
            if (request.receive_count == request.receives.len) return error.InvalidIpc;
            request.receives[request.receive_count] = buffer;
            request.receive_count += 1;
        }
        try advance(&cursor, 12);
    }
    const raw_start = cursor;
    try advance(&cursor, data_words * 4);
    const raw_end = cursor;
    const receive_count = if (receive_mode > 2) receive_mode - 2 else 0;
    for (0..receive_count) |_| {
        const a = try word(&request.bytes, cursor);
        const b = try word(&request.bytes, cursor + 4);
        const buffer: Buffer = .{ .address = @as(u64, a) | (@as(u64, b & 0xffff) << 32), .size = b >> 16 };
        try validateRange(memory, buffer.address, buffer.size, true);
        if (request.receive_count == request.receives.len) return error.InvalidIpc;
        request.receives[request.receive_count] = buffer;
        request.receive_count += 1;
        try advance(&cursor, 8);
    }
    if (request.message_type == 2) return request;
    var payload = std.mem.alignForward(usize, raw_start, 16);
    var payload_end = raw_end;
    if (domain and (request.message_type == 4 or request.message_type == 6)) {
        if (payload > raw_end or raw_end - payload < 16) return error.InvalidIpc;
        request.domain_type = request.bytes[payload];
        request.domain_object = try word(&request.bytes, payload + 4);
        const data_size = std.mem.readInt(u16, request.bytes[payload + 2 ..][0..2], .little);
        payload += 16;
        if (data_size > raw_end - payload) return error.InvalidIpc;
        if (request.domain_type == 2) return request;
        payload_end = payload + data_size;
    }
    if (payload > payload_end or payload_end - payload < 16) return error.InvalidIpc;
    if (try word(&request.bytes, payload) != 0x49434653) return error.InvalidIpc;
    if (try word(&request.bytes, payload + 4) > 1) return error.InvalidIpc;
    request.command_id = try word(&request.bytes, payload + 8);
    request.token = try word(&request.bytes, payload + 12);
    request.payload_offset = payload + 16;
    request.payload_end = payload_end;
    return request;
}

pub const Response = struct {
    result: u32 = 0,
    payload: [128]u8 = @splat(0),
    payload_length: usize = 0,
    copy_handle: ?u32 = null,
    move_handle: ?u32 = null,
    domain_object: ?u32 = null,

    pub fn integer(self: *Response, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.payload[self.payload_length..][0..@sizeOf(T)], value, .little);
        self.payload_length += @sizeOf(T);
    }
};

pub const Parcel = struct {
    bytes: [1024]u8 = @splat(0),
    position: usize = 16,
    end: usize = 16,

    pub fn read(memory: *const Memory, buffer: Buffer) !Parcel {
        if (buffer.size < 16 or buffer.size > 1024) return error.InvalidIpc;
        var parcel: Parcel = .{};
        try memory.read(buffer.address, parcel.bytes[0..buffer.size]);
        const length = try word(&parcel.bytes, 0);
        const offset = try word(&parcel.bytes, 4);
        const objects_length = try word(&parcel.bytes, 8);
        const objects_offset = try word(&parcel.bytes, 12);
        if (offset < 16 or offset > buffer.size or length > buffer.size - offset) return error.InvalidIpc;
        if (objects_offset > buffer.size or objects_length > buffer.size - objects_offset) return error.InvalidIpc;
        if (objects_length != 0) return error.InvalidIpc;
        parcel.position = offset;
        parcel.end = offset + length;
        return parcel;
    }

    pub fn take(self: *Parcel, comptime T: type) !T {
        if (self.position > self.end or @sizeOf(T) > self.end - self.position) return error.InvalidIpc;
        const value = std.mem.readInt(T, self.bytes[self.position..][0..@sizeOf(T)], .little);
        self.position += @sizeOf(T);
        return value;
    }

    pub fn object(self: *Parcel) ![]const u8 {
        const length = try self.take(u32);
        const fd_count = try self.take(u32);
        if (fd_count != 0 or length > self.end - self.position) return error.InvalidIpc;
        const start = self.position;
        self.position = std.mem.alignForward(usize, self.position + length, 4);
        if (self.position > self.end) return error.InvalidIpc;
        return self.bytes[start..][0..length];
    }

    pub fn interface(self: *Parcel, name: []const u8) !void {
        _ = try self.take(u32);
        const count = try self.take(u32);
        if (count != name.len) return error.InvalidIpc;
        for (name) |character| if (try self.take(u16) != character) return error.InvalidIpc;
        if (try self.take(u16) != 0) return error.InvalidIpc;
        self.position = std.mem.alignForward(usize, self.position, 4);
        if (self.position > self.end) return error.InvalidIpc;
    }

    pub fn put(self: *Parcel, comptime T: type, value: T) !void {
        if (@sizeOf(T) > self.bytes.len - self.end) return error.InvalidIpc;
        std.mem.writeInt(T, self.bytes[self.end..][0..@sizeOf(T)], value, .little);
        self.end += @sizeOf(T);
    }

    pub fn putObject(self: *Parcel, bytes: []const u8) !void {
        try self.put(u32, @intCast(bytes.len));
        try self.put(u32, 0);
        if (bytes.len > self.bytes.len - self.end) return error.InvalidIpc;
        @memcpy(self.bytes[self.end..][0..bytes.len], bytes);
        self.end = std.mem.alignForward(usize, self.end + bytes.len, 4);
    }

    pub fn write(self: *Parcel, memory: *Memory, buffer: Buffer) !void {
        if (buffer.size < self.end) return error.InvalidIpc;
        std.mem.writeInt(u32, self.bytes[0..4], @intCast(self.end - 16), .little);
        std.mem.writeInt(u32, self.bytes[4..8], 16, .little);
        std.mem.writeInt(u32, self.bytes[8..12], 0, .little);
        std.mem.writeInt(u32, self.bytes[12..16], @intCast(self.end), .little);
        try memory.write(buffer.address, self.bytes[0..self.end]);
    }
};

pub fn respond(memory: *Memory, address: u64, request: *const Request, response: *const Response, domain: bool) !void {
    var bytes: [message_size]u8 = @splat(0);
    var cursor: usize = 8;
    const special = response.copy_handle != null or response.move_handle != null;
    if (special) {
        const bits: u32 = (if (response.copy_handle != null) @as(u32, 1 << 1) else 0) | (if (response.move_handle != null) @as(u32, 1 << 5) else 0);
        std.mem.writeInt(u32, bytes[cursor..][0..4], bits, .little);
        cursor += 4;
        if (response.copy_handle) |handle| {
            std.mem.writeInt(u32, bytes[cursor..][0..4], handle, .little);
            cursor += 4;
        }
        if (response.move_handle) |handle| {
            std.mem.writeInt(u32, bytes[cursor..][0..4], handle, .little);
            cursor += 4;
        }
    }
    const raw_start = cursor;
    cursor = std.mem.alignForward(usize, cursor, 16);
    if (domain) {
        std.mem.writeInt(u32, bytes[cursor..][0..4], @intFromBool(response.domain_object != null), .little);
        cursor += 16;
    }
    std.mem.writeInt(u32, bytes[cursor..][0..4], 0x4f434653, .little);
    std.mem.writeInt(u32, bytes[cursor + 8 ..][0..4], response.result, .little);
    std.mem.writeInt(u32, bytes[cursor + 12 ..][0..4], request.token, .little);
    cursor += 16;
    if (response.payload_length > response.payload.len or response.payload_length > bytes.len - cursor) return error.InvalidIpc;
    @memcpy(bytes[cursor..][0..response.payload_length], response.payload[0..response.payload_length]);
    cursor += response.payload_length;
    cursor = std.mem.alignForward(usize, cursor, 4);
    if (response.domain_object) |object| {
        std.mem.writeInt(u32, bytes[cursor..][0..4], object, .little);
        cursor += 4;
    }
    std.mem.writeInt(u32, bytes[4..8], @as(u32, @intCast((cursor - raw_start + 3) / 4)) | (if (special) @as(u32, 1 << 31) else 0), .little);
    try memory.write(address, &bytes);
}

test "HIPC rejects descriptor overflow and unmapped output before service dispatch" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    try memory.writeInt(u32, 0x1000, 4);
    try memory.writeInt(u32, 0x1004, 1023);
    try std.testing.expectError(error.InvalidIpc, parse(&memory, 0x1000, false));
    try memory.writeInt(u32, 0x1000, 4 | (1 << 24));
    try memory.writeInt(u32, 0x1004, 8);
    try memory.writeInt(u32, 0x1008, 32);
    try memory.writeInt(u32, 0x100c, 0x5000);
    try std.testing.expectError(error.InvalidIpc, parse(&memory, 0x1000, false));
}

test "CMIF preserves token and separates SFCO result from transport" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    try memory.writeInt(u32, 0x1000, 4);
    try memory.writeInt(u32, 0x1004, 8);
    try memory.writeInt(u32, 0x1010, 0x49434653);
    try memory.writeInt(u32, 0x1018, 7);
    try memory.writeInt(u32, 0x101c, 0x1234);
    const request = try parse(&memory, 0x1000, false);
    try std.testing.expectEqual(@as(u32, 7), request.command_id);
    const response: Response = .{ .result = 0xf601, .move_handle = 0x201 };
    try respond(&memory, 0x1000, &request, &response, false);
    try std.testing.expectEqual(@as(u32, 0x201), try memory.readInt(u32, 0x100c));
    try std.testing.expectEqual(@as(u32, 0x4f434653), try memory.readInt(u32, 0x1010));
    try std.testing.expectEqual(@as(u32, 0xf601), try memory.readInt(u32, 0x1018));
    try std.testing.expectEqual(@as(u32, 0x1234), try memory.readInt(u32, 0x101c));
}
