const std = @import("std");
const Cpu = @import("../cpu/aarch64.zig").Cpu;
const Memory = @import("../memory/address_space.zig").Memory;
const homebrew = @import("../loader/homebrew.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const Services = @import("services.zig").Services;

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
    services: Services,

    pub fn init(allocator: std.mem.Allocator) Kernel {
        return .{ .allocator = allocator, .services = Services.init(allocator) };
    }

    pub fn deinit(self: *Kernel) void {
        self.services.deinit();
        self.debug_output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pollWaiters(self: *Kernel) void {
        for (&self.scheduler.threads) |*thread| {
            if (thread.state != .waiting and thread.state != .sleeping) {
                thread.wait_count = 0;
                continue;
            }
            if (thread.wait_count == 0) continue;
            var ready_index: ?usize = null;
            var invalid = false;
            for (thread.wait_handles[0..thread.wait_count], 0..) |handle, index| {
                const signaled = if (self.scheduler.find(handle)) |other| other.state == .exited else self.services.isSignaled(handle) catch {
                    invalid = true;
                    break;
                };
                if (signaled and ready_index == null) ready_index = index;
            }
            if (invalid or ready_index != null) {
                thread.cpu.x[0] = if (invalid) Result.invalid_handle else 0;
                thread.cpu.x[1] = ready_index orelse 0;
                thread.state = .ready;
                thread.wait_count = 0;
            }
        }
    }

    pub fn dispatch(self: *Kernel, cpu: *Cpu, memory: *Memory, svc: u16) !Control {
        self.svc_count += 1;
        self.last_svc = svc;
        const elapsed = (@as(u128, self.scheduler.ticks) * 1_000_000_000) / 19_200_000;
        self.services.elapsed_ns = @intCast(@min(elapsed, std.math.maxInt(u64)));
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
                const priority = std.math.cast(u32, cpu.x[4]) orelse {
                    cpu.x[0] = Result.invalid_size;
                    return .running;
                };
                const handle = self.scheduler.create(memory, cpu.x[1], cpu.x[2], cpu.x[3], priority) catch {
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
            0x0a => {
                self.scheduler.exitCurrent();
                try self.scheduler.reapClosed(memory);
            },
            0x0b => {
                self.scheduler.sleep(@bitCast(cpu.x[0]));
                cpu.x[0] = 0;
            },
            0x0c => {
                const thread = self.scheduler.find(cpu.x[1]) orelse {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                cpu.x[0] = 0;
                cpu.x[1] = thread.priority;
            },
            0x10 => cpu.x[0] = 0,
            0x11, 0x12, 0x17 => {
                const handle = std.math.cast(u32, cpu.x[0]) orelse {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                const outcome = if (svc == 0x11) self.services.signalEvent(handle) else self.services.resetEvent(handle);
                cpu.x[0] = if (outcome) |_| 0 else |_| Result.invalid_handle;
            },
            0x13 => {
                self.services.mapShared(memory, @truncate(cpu.x[0]), cpu.x[1], @intCast(cpu.x[2]), @truncate(cpu.x[3])) catch {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                cpu.x[0] = 0;
            },
            0x14 => {
                self.services.unmapShared(memory, @truncate(cpu.x[0]), cpu.x[1], @intCast(cpu.x[2])) catch {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                cpu.x[0] = 0;
            },
            0x15 => {
                const handle = try self.services.createTransfer(cpu.x[1], @intCast(cpu.x[2]), @truncate(cpu.x[3]));
                cpu.x[0] = 0;
                cpu.x[1] = handle;
            },
            0x16 => {
                const handle = std.math.cast(u32, cpu.x[0]) orelse {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                const outcome = if (self.scheduler.find(handle) != null) self.scheduler.close(memory, handle) else self.services.close(handle);
                outcome catch {
                    cpu.x[0] = Result.invalid_handle;
                    return .running;
                };
                cpu.x[0] = 0;
            },
            0x18 => {
                if (cpu.x[2] == 0 or cpu.x[2] > 64) {
                    cpu.x[0] = Result.invalid_size;
                    return .running;
                }
                var handles: [64]u32 = undefined;
                const count: usize = @intCast(cpu.x[2]);
                for (handles[0..count], 0..) |*handle, index| handle.* = try memory.readInt(u32, cpu.x[1] + index * 4);
                var ready_index: ?usize = null;
                for (0..count) |index| {
                    const handle = handles[index];
                    const signaled = if (self.scheduler.find(handle)) |thread| thread.state == .exited else self.services.isSignaled(handle) catch {
                        cpu.x[0] = Result.invalid_handle;
                        return .running;
                    };
                    if (signaled and ready_index == null) ready_index = index;
                }
                if (ready_index) |index| {
                    cpu.x[0] = 0;
                    cpu.x[1] = index;
                    return .running;
                }
                const timeout: i64 = @bitCast(cpu.x[3]);
                if (timeout != 0) self.scheduler.wait(handles[0..count], timeout);
                cpu.x[0] = 0xea01;
                cpu.x[1] = 0;
            },
            0x1e => cpu.x[0] = self.scheduler.ticks,
            0x1f => {
                var name: [32]u8 = undefined;
                var length: usize = 0;
                while (length < name.len) : (length += 1) {
                    name[length] = try memory.readInt(u8, cpu.x[1] + length);
                    if (name[length] == 0) break;
                }
                if (length == name.len) return error.InvalidPortName;
                const handle = self.services.connect(name[0..length]) catch {
                    cpu.x[0] = Result.not_implemented;
                    return .running;
                };
                cpu.x[0] = 0;
                cpu.x[1] = handle;
            },
            0x21 => cpu.x[0] = try self.services.send(memory, cpu.tpidrro_el0, @truncate(cpu.x[0])),
            0x22 => {
                if (cpu.x[1] < 0x100 or cpu.x[1] > 0x1000) {
                    cpu.x[0] = Result.invalid_size;
                } else cpu.x[0] = try self.services.send(memory, cpu.x[0], @truncate(cpu.x[2]));
            },
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

test "thread priority SVC validates wide inputs and returns each stored priority" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0xd503201f);
    var cpu: Cpu = .{ .pc = 0x1000 };
    var kernel = Kernel.init(std.testing.allocator);
    defer kernel.deinit();
    kernel.scheduler = Scheduler.init(cpu);
    cpu.x[1] = 0x1000;
    cpu.x[3] = 0x2000;
    cpu.x[4] = 0x100000000;
    _ = try kernel.dispatch(&cpu, &memory, 0x08);
    try std.testing.expectEqual(@as(u64, Result.invalid_size), cpu.x[0]);
    try std.testing.expectEqual(@as(usize, 0x1000), memory.mapped_bytes);
    cpu.x[4] = 20;
    _ = try kernel.dispatch(&cpu, &memory, 0x08);
    const handle = cpu.x[1];
    try std.testing.expectEqual(@as(u64, 0), cpu.x[0]);
    _ = try kernel.dispatch(&cpu, &memory, 0x0c);
    try std.testing.expectEqual(@as(u64, 20), cpu.x[1]);
    cpu.x[1] = 0xffff0000;
    _ = try kernel.dispatch(&cpu, &memory, 0x0c);
    try std.testing.expectEqual(@as(u64, Result.invalid_handle), cpu.x[0]);
    cpu.x[0] = handle;
    _ = try kernel.dispatch(&cpu, &memory, 0x16);
    try std.testing.expectEqual(@as(u64, 0), cpu.x[0]);
    try std.testing.expect(kernel.scheduler.find(handle) == null);
    try std.testing.expectEqual(@as(usize, 0x1000), memory.mapped_bytes);
}

test "wait validates every handle and timeout cannot resurrect an exited thread" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    var cpu: Cpu = .{};
    var kernel = Kernel.init(std.testing.allocator);
    defer kernel.deinit();
    kernel.scheduler = Scheduler.init(cpu);
    const event = try kernel.services.createEvent(true);
    try memory.writeInt(u32, 0x1000, event);
    try memory.writeInt(u32, 0x1004, 0xffffffff);
    cpu.x[1] = 0x1000;
    cpu.x[2] = 2;
    _ = try kernel.dispatch(&cpu, &memory, 0x18);
    try std.testing.expectEqual(@as(u64, Result.invalid_handle), cpu.x[0]);
    try kernel.services.resetEvent(event);
    cpu.x[1] = 0x1000;
    cpu.x[2] = 1;
    cpu.x[3] = 1;
    _ = try kernel.dispatch(&cpu, &memory, 0x18);
    try kernel.scheduler.advance(&cpu);
    try std.testing.expectEqual(@as(u64, 0xea01), cpu.x[0]);
    kernel.scheduler.exitCurrent();
    try kernel.services.signalEvent(event);
    kernel.pollWaiters();
    try std.testing.expectEqual(@import("scheduler.zig").State.exited, kernel.scheduler.threads[0].state);
    try std.testing.expectEqual(@as(u7, 0), kernel.scheduler.threads[0].wait_count);
}

test "service elapsed time saturates after long guest sleeps" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    var cpu: Cpu = .{};
    var kernel = Kernel.init(std.testing.allocator);
    defer kernel.deinit();
    kernel.scheduler.ticks = std.math.maxInt(u64);
    _ = try kernel.dispatch(&cpu, &memory, 0x10);
    try std.testing.expectEqual(std.math.maxInt(u64), kernel.services.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 0), cpu.x[0]);
}
