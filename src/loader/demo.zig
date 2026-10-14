const std = @import("std");

pub const message = "Hello from Zigium homebrew!\n";
pub const service_message = "Zigium SM/APM homebrew demo passed.\n";

fn image(allocator: std.mem.Allocator) ![]u8 {
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
    return bytes;
}

pub fn hello(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try image(allocator);
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

const Code = struct {
    bytes: []u8,
    cursor: usize = 0x80,
    failures: [16]usize = undefined,
    failure_count: usize = 0,

    fn emit(self: *Code, instruction: u32) void {
        put(self.bytes, self.cursor, instruction);
        self.cursor += 4;
    }

    fn adr(self: *Code, register: u5, target: usize) void {
        const delta: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(self.cursor));
        const immediate: u32 = @bitCast(delta);
        self.emit(0x10000000 | ((immediate & 3) << 29) | (((immediate >> 2) & 0x7ffff) << 5) | register);
    }

    fn failIf(self: *Code, instruction: u32) void {
        self.failures[self.failure_count] = self.cursor;
        self.failure_count += 1;
        self.emit(instruction);
    }

    fn copyRequest(self: *Code, offset: usize) void {
        self.emit(0xd53bd063);
        self.adr(4, offset);
        for (0..4) |pair| {
            const immediate: u32 = @intCast(pair * 2);
            self.emit(0xa9401885 | (immediate << 15));
            self.emit(0xa9001865 | (immediate << 15));
        }
    }

    fn send(self: *Code, handle_register: u5) void {
        self.emit(0xaa0003e0 | (@as(u32, handle_register) << 16));
        self.emit(0xd4000421);
        self.failIf(0x35000000);
        self.emit(0xd53bd063);
        self.emit(0xb9401064);
        self.emit(0x52800005 | (@as(u32, 0x4653) << 5));
        self.emit(0x72a00005 | (@as(u32, 0x4f43) << 5));
        self.emit(0x6b05009f);
        self.failIf(0x54000001);
        self.emit(0xb9401864);
        self.failIf(0x35000004);
    }

    fn finish(self: *Code) void {
        const failure = self.cursor;
        self.emit(0xd2800020);
        self.emit(0xd40000e1);
        self.emit(0x14000000);
        for (self.failures[0..self.failure_count]) |branch| {
            const delta: u32 = @intCast((failure - branch) / 4);
            const instruction = std.mem.readInt(u32, self.bytes[branch..][0..4], .little);
            put(self.bytes, branch, instruction | (delta << 5));
        }
    }
};

pub fn services(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try image(allocator);
    @memcpy(bytes[0x1000..0x1004], "sm:\x00");
    @memcpy(bytes[0x1020..][0..service_message.len], service_message);
    put(bytes, 0x1100, 4);
    put(bytes, 0x1104, (1 << 31) | 10);
    put(bytes, 0x1108, 1);
    put(bytes, 0x1120, 0x49434653);
    put(bytes, 0x1140, 4);
    put(bytes, 0x1144, 10);
    put(bytes, 0x1150, 0x49434653);
    put(bytes, 0x1158, 1);
    @memcpy(bytes[0x1160..0x1168], "apm\x00\x00\x00\x00\x00");
    put(bytes, 0x1180, 4);
    put(bytes, 0x1184, 8);
    put(bytes, 0x1190, 0x49434653);
    put(bytes, 0x1198, 1);
    var code: Code = .{ .bytes = bytes };
    code.adr(1, 0x1000);
    code.emit(0xd40003e1);
    code.failIf(0x35000000);
    code.emit(0xaa0103f4);
    code.failIf(0xb4000014);
    code.copyRequest(0x1100);
    code.send(20);
    code.copyRequest(0x1140);
    code.send(20);
    code.emit(0xb9400c75);
    code.failIf(0x34000015);
    code.copyRequest(0x1180);
    code.send(21);
    code.adr(0, 0x1020);
    code.emit(0xd2800001 | (@as(u32, service_message.len) << 5));
    code.emit(0xd40004e1);
    code.emit(0xd2800000);
    code.emit(0xd40000e1);
    code.emit(0x14000000);
    code.finish();
    return bytes;
}

fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

test "service NRO exits with failure when CMIF returns an unsupported command" {
    const Memory = @import("../memory/address_space.zig").Memory;
    const Cpu = @import("../cpu/aarch64.zig").Cpu;
    const Kernel = @import("../kernel/kernel.zig").Kernel;
    const Scheduler = @import("../kernel/scheduler.zig").Scheduler;
    const nro = @import("nro.zig");
    const bytes = try services(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    put(bytes, 0x1198, 0xffff);
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    const loaded = try nro.load(&memory, bytes);
    try memory.map(0x7400000000, 0x1000, .{ .read = true, .write = true });
    var cpu: Cpu = .{ .pc = loaded.entry, .tpidrro_el0 = 0x7400000000 };
    var kernel = Kernel.init(std.testing.allocator);
    defer kernel.deinit();
    kernel.scheduler = Scheduler.init(cpu);
    var exited = false;
    for (0..256) |_| {
        switch (try cpu.step(&memory)) {
            .next => {},
            .svc => |id| if (try kernel.dispatch(&cpu, &memory, id) == .exited) {
                exited = true;
                break;
            },
            .brk => return error.UnexpectedGuestBreakpoint,
        }
    }
    try std.testing.expect(exited);
    try std.testing.expectEqual(@as(u64, 1), kernel.exit_code);
    try std.testing.expectEqual(@as(u64, 3), kernel.services.request_count);
    try std.testing.expectEqual(@as(u64, 5), kernel.svc_count);
    try std.testing.expectEqual(@as(usize, 0), kernel.debug_output.items.len);
}
