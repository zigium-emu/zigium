const std = @import("std");
const Cpu = @import("../cpu/aarch64.zig").Cpu;
const Memory = @import("../memory/address_space.zig").Memory;
const homebrew = @import("../loader/homebrew.zig");
const Scheduler = @import("scheduler.zig").Scheduler;

pub const Control = enum { running, exited };
pub const Result = struct {
    pub const success: u32 = 0;
    pub const invalid_handle: u32 = 0xe401;
    pub const invalid_size: u32 = 0xca01;
    pub const not_implemented: u32 = 0xf601;
    pub const invalid_enum: u32 = 0xf001;
};

pub const Kernel = struct {
    allocator: std.mem.Allocator,
    debug_output: std.ArrayList(u8) = .empty,
    svc_count: u64 = 0,
    last_svc: u16 = 0,
    exit_code: u64 = 0,
    scheduler: Scheduler = .{},

    pub fn init(allocator: std.mem.Allocator) Kernel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Kernel) void {
        self.debug_output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dispatch(self: *Kernel, cpu: *Cpu, memory: *Memory, svc: u16) !Control {
        self.svc_count += 1;
        self.last_svc = svc;
        switch (svc) {
            0x01 => {
                if (cpu.x[1] == 0 or cpu.x[1] > homebrew.heap_size or cpu.x[1] % (2 * 1024 * 1024) != 0) {
                    cpu.x[0] = Result.invalid_size;
                } else {
                    cpu.x[0] = 0;
                    cpu.x[1] = homebrew.heap_base;
                }
            },
            0x06 => {
                const info = try memory.query(cpu.x[2]);
                var output: [0x28]u8 = @splat(0);
                std.mem.writeInt(u64, output[0..8], info.base, .little);
                std.mem.writeInt(u64, output[8..16], info.size, .little);
                std.mem.writeInt(u32, output[16..20], info.state, .little);
                std.mem.writeInt(u32, output[24..28], info.permissions.bits(), .little);
                try memory.write(cpu.x[0], &output);
                cpu.x[0] = 0;
                cpu.x[1] = 0;
            },
            0x07 => {
                self.exit_code = cpu.x[0];
                return .exited;
            },
            0x08 => {
                const handle = self.scheduler.create(memory, cpu.x[1], cpu.x[2], cpu.x[3], @intCast(cpu.x[4])) catch {
                    cpu.x[0] = Result.invalid_size;
                    return .running;
                };
                cpu.x[0] = 0;
                cpu.x[1] = handle;
            },
            0x09 => {
                self.scheduler.start(cpu.x[0]) catch {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                cpu.x[0] = 0;
            },
            0x0a => self.scheduler.exitCurrent(),
            0x0b => {
                self.scheduler.sleep(@bitCast(cpu.x[0]));
                cpu.x[0] = 0;
            },
            0x0c => {
                cpu.x[0] = 0;
                cpu.x[1] = 44;
            },
            0x10 => cpu.x[0] = 0,
            0x1e => cpu.x[0] = self.scheduler.ticks,
            0x24, 0x25 => {
                if (cpu.x[1] == homebrew.main_thread_handle or cpu.x[1] == 0xffff8000 or cpu.x[1] == 0xffff8001) {
                    cpu.x[0] = 0;
                    cpu.x[1] = 1;
                } else cpu.x[0] = Result.invalid_handle;
            },
            0x26 => return error.GuestBreak,
            0x27 => {
                const length = cpu.x[1];
                if (length > 64 * 1024 or self.debug_output.items.len + length > 1024 * 1024) return error.DebugOutputLimit;
                const old_length = self.debug_output.items.len;
                try self.debug_output.resize(self.allocator, old_length + @as(usize, @intCast(length)));
                errdefer self.debug_output.shrinkRetainingCapacity(old_length);
                try memory.read(cpu.x[0], self.debug_output.items[old_length..]);
                cpu.x[0] = 0;
            },
            0x29 => {
                const value: ?u64 = switch (cpu.x[1]) {
                    0 => 1,
                    1 => 1 << 44,
                    2 => 0x7500000000,
                    3 => 0x10000000,
                    4 => homebrew.heap_base,
                    5 => homebrew.heap_size,
                    6 => 512 * 1024 * 1024,
                    7 => memory.mapped_bytes,
                    11 => 0,
                    12 => 0,
                    13 => @import("../memory/address_space.zig").address_limit,
                    14 => 0x7100000000,
                    15 => 0x100000000,
                    18 => 0x5a494749554d0001,
                    else => null,
                };
                if (value) |v| {
                    cpu.x[0] = 0;
                    cpu.x[1] = v;
                } else cpu.x[0] = Result.invalid_enum;
            },
            else => return error.UnsupportedSvc,
        }
        return .running;
    }
};

test "SVC debug validates guest buffer and limits output" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    try memory.write(0x1000, "hello");
    var cpu: Cpu = .{};
    var kernel = Kernel.init(std.testing.allocator);
    defer kernel.deinit();
    cpu.x[0] = 0x1000;
    cpu.x[1] = 5;
    _ = try kernel.dispatch(&cpu, &memory, 0x27);
    try std.testing.expectEqualStrings("hello", kernel.debug_output.items);
    cpu.x[0] = 0x3000;
    cpu.x[1] = 4;
    try std.testing.expectError(error.MemoryFault, kernel.dispatch(&cpu, &memory, 0x27));
    try std.testing.expectEqualStrings("hello", kernel.debug_output.items);
}

test "SVC QueryMemory uses output pointer and register result ABI" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    var cpu: Cpu = .{};
    var kernel = Kernel.init(std.testing.allocator);
    defer kernel.deinit();
    cpu.x[0] = 0x1100;
    cpu.x[1] = 0xffff;
    cpu.x[2] = 0x1800;
    _ = try kernel.dispatch(&cpu, &memory, 6);
    try std.testing.expectEqual(@as(u64, 0x1000), try memory.readInt(u64, 0x1100));
    try std.testing.expectEqual(@as(u32, 3), try memory.readInt(u32, 0x1118));
    try std.testing.expectEqual(@as(u64, 0), cpu.x[1]);
}
