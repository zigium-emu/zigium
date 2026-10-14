const std = @import("std");
const Cpu = @import("../cpu/aarch64.zig").Cpu;
const Memory = @import("../memory/address_space.zig").Memory;

pub const State = enum { unused, created, ready, sleeping, waiting, exited };
pub const Thread = struct {
    handle: u32 = 0,
    handle_open: bool = false,
    tls: u64 = 0,
    cpu: Cpu = .{},
    state: State = .unused,
    wake_tick: u64 = 0,
    priority: u32 = 44,
    wait_handles: [64]u32 = @splat(0),
    wait_count: u7 = 0,
};

pub const Scheduler = struct {
    threads: [32]Thread = @splat(.{}),
    current: usize = 0,
    ticks: u64 = 0,
    quantum_remaining: u32 = 10_000,
    needs_switch: bool = false,
    next_thread_id: u32 = 1,

    pub fn init(main: Cpu) Scheduler {
        var scheduler: Scheduler = .{};
        scheduler.threads[0] = .{ .handle = 0x100, .handle_open = true, .tls = main.tpidrro_el0, .cpu = main, .state = .ready };
        return scheduler;
    }

    pub fn create(self: *Scheduler, memory: *Memory, entry: u64, argument: u64, stack: u64, priority: u32) !u32 {
        if (entry & 3 != 0 or stack & 15 != 0 or priority > 63) return error.InvalidThread;
        _ = try memory.fetch(entry);
        for (self.threads[1..], 1..) |*thread, index| {
            if (thread.state == .unused) {
                if (self.next_thread_id >= 0x7fff8000) return error.ThreadLimit;
                const tls = 0x7400010000 + index * 0x1000;
                try memory.mapWithState(tls, 0x1000, .{ .read = true, .write = true }, 0xc);
                const handle = 0x80000000 | self.next_thread_id;
                self.next_thread_id += 1;
                var cpu: Cpu = .{ .pc = entry, .sp = stack, .tpidrro_el0 = tls, .tpidr_el0 = tls };
                cpu.x[0] = argument;
                cpu.x[1] = handle;
                thread.* = .{ .handle = handle, .handle_open = true, .tls = tls, .cpu = cpu, .state = .created, .priority = priority };
                return handle;
            }
        }
        return error.ThreadLimit;
    }

    pub fn find(self: *Scheduler, handle: u64) ?*Thread {
        if (handle == 0xffff8000 and self.threads[self.current].state != .unused) return &self.threads[self.current];
        for (&self.threads) |*thread| if (thread.state != .unused and thread.handle_open and thread.handle == handle) return thread;
        return null;
    }

    pub fn start(self: *Scheduler, handle: u64) !void {
        const thread = self.find(handle) orelse return error.InvalidHandle;
        if (thread.state != .created) return error.InvalidThreadState;
        thread.state = .ready;
    }

    pub fn sleep(self: *Scheduler, duration_ns: i64) void {
        self.threads[self.current].wait_count = 0;
        if (duration_ns > 0) {
            const duration: u64 = @intCast((@as(u128, @intCast(duration_ns)) * 19_200_000) / 1_000_000_000);
            self.threads[self.current].wake_tick = self.ticks +| @max(duration, 1);
            self.threads[self.current].state = .sleeping;
        }
        self.needs_switch = true;
    }

    pub fn exitCurrent(self: *Scheduler) void {
        self.threads[self.current].state = .exited;
        self.threads[self.current].wait_count = 0;
        self.needs_switch = true;
    }

    pub fn close(self: *Scheduler, memory: *Memory, handle: u64) !void {
        if (handle == 0xffff8000) return error.InvalidHandle;
        const thread = self.find(handle) orelse return error.InvalidHandle;
        thread.handle_open = false;
        try self.reapClosed(memory);
    }

    pub fn reapClosed(self: *Scheduler, memory: *Memory) !void {
        for (&self.threads) |*thread| {
            if (!thread.handle_open and (thread.state == .created or thread.state == .exited)) {
                if (thread.tls != 0) try memory.unmap(thread.tls, 0x1000);
                thread.* = .{};
            }
        }
    }

    pub fn wait(self: *Scheduler, handles: []const u32, timeout_ns: i64) void {
        const thread = &self.threads[self.current];
        if (timeout_ns > 0) self.sleep(timeout_ns) else {
            thread.state = .waiting;
            self.needs_switch = true;
        }
        @memcpy(thread.wait_handles[0..handles.len], handles);
        thread.wait_count = @intCast(handles.len);
    }

    pub fn activateReady(self: *Scheduler, cpu: *Cpu) !void {
        self.current = self.nextReady() orelse return error.NoRunnableThreads;
        cpu.* = self.threads[self.current].cpu;
        cpu.counter = self.ticks;
        cpu.clearExclusive();
        self.needs_switch = false;
        self.quantum_remaining = 10_000;
    }

    pub fn advance(self: *Scheduler, cpu: *Cpu) !void {
        self.ticks +|= 1;
        cpu.counter = self.ticks;
        self.quantum_remaining -= 1;
        if (!self.needs_switch and self.quantum_remaining != 0) return;
        self.threads[self.current].cpu = cpu.*;
        var earliest: u64 = std.math.maxInt(u64);
        for (&self.threads) |*thread| {
            if (thread.state == .sleeping) {
                if (thread.wake_tick <= self.ticks) {
                    thread.state = .ready;
                    thread.wait_count = 0;
                } else earliest = @min(earliest, thread.wake_tick);
            }
        }
        var next = self.nextReady();
        if (next == null and earliest != std.math.maxInt(u64)) {
            self.ticks = earliest;
            for (&self.threads) |*thread| if (thread.state == .sleeping and thread.wake_tick <= earliest) {
                thread.state = .ready;
                thread.wait_count = 0;
            };
            next = self.nextReady();
        }
        self.current = next orelse return error.NoRunnableThreads;
        cpu.* = self.threads[self.current].cpu;
        cpu.counter = self.ticks;
        cpu.clearExclusive();
        self.needs_switch = false;
        self.quantum_remaining = 10_000;
    }

    fn nextReady(self: *const Scheduler) ?usize {
        for (1..self.threads.len + 1) |offset| {
            const index = (self.current + offset) % self.threads.len;
            if (self.threads[index].state == .ready) return index;
        }
        return null;
    }
};

test "thread starts with own TLS, argument, and resumes main after exit" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0xd503201f);
    var cpu: Cpu = .{ .pc = 0x1000, .sp = 0x2000 };
    var scheduler = Scheduler.init(cpu);
    const handle = try scheduler.create(&memory, 0x1000, 42, 0x3000, 44);
    try scheduler.start(handle);
    scheduler.sleep(0);
    try scheduler.advance(&cpu);
    try std.testing.expectEqual(@as(u64, 42), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, handle), cpu.x[1]);
    try std.testing.expect(cpu.tpidrro_el0 != 0);
    scheduler.exitCurrent();
    try scheduler.advance(&cpu);
    try std.testing.expectEqual(@as(usize, 0), scheduler.current);
    try std.testing.expectEqual(@as(u64, 0x2000), cpu.sp);
}

test "single sleeping thread wakes deterministically without spinning" {
    var cpu: Cpu = .{};
    var scheduler = Scheduler.init(cpu);
    scheduler.sleep(1_000_000_000);
    try scheduler.advance(&cpu);
    try std.testing.expectEqual(@as(u64, 19_200_000), scheduler.ticks);
    try std.testing.expectEqual(State.ready, scheduler.threads[0].state);
}

test "closing created threads reclaims TLS and never reuses a stale handle" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0xd503201f);
    var scheduler = Scheduler.init(.{ .pc = 0x1000 });
    var previous: u32 = 0;
    for (0..100) |_| {
        const before = memory.mapped_bytes;
        const handle = try scheduler.create(&memory, 0x1000, 0, 0x2000, 20);
        try std.testing.expect(handle >= 0x80000000 and handle < 0xffff8000);
        try std.testing.expect(handle != previous);
        try std.testing.expectEqual(before + 0x1000, memory.mapped_bytes);
        const tls = scheduler.find(handle).?.tls;
        try scheduler.close(&memory, handle);
        try std.testing.expect(scheduler.find(handle) == null);
        try std.testing.expectEqual(before, memory.mapped_bytes);
        try std.testing.expectEqual(@as(u32, 0), (try memory.query(tls)).state);
        try std.testing.expectError(error.InvalidHandle, scheduler.start(handle));
        previous = handle;
    }
}

test "closing a running thread preserves execution and frees TLS after exit" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0xd503201f);
    var cpu: Cpu = .{ .pc = 0x1000 };
    var scheduler = Scheduler.init(cpu);
    const handle = try scheduler.create(&memory, 0x1000, 42, 0x2000, 20);
    const tls = scheduler.find(handle).?.tls;
    try scheduler.start(handle);
    scheduler.sleep(0);
    try scheduler.advance(&cpu);
    try scheduler.close(&memory, handle);
    try std.testing.expect(scheduler.find(handle) == null);
    try std.testing.expectEqual(State.ready, scheduler.threads[scheduler.current].state);
    try std.testing.expectEqual(@as(u32, 0xc), (try memory.query(tls)).state);
    try std.testing.expectEqual(@as(u64, 42), cpu.x[0]);
    scheduler.exitCurrent();
    try scheduler.reapClosed(&memory);
    try scheduler.advance(&cpu);
    try std.testing.expectEqual(@as(usize, 0), scheduler.current);
    try std.testing.expectEqual(@as(u32, 0), (try memory.query(tls)).state);
}

test "timed waits clear their registration and large sleeps keep ticks monotonic" {
    var cpu: Cpu = .{};
    var scheduler = Scheduler.init(cpu);
    scheduler.wait(&.{0x200}, 1);
    try std.testing.expectEqual(@as(u7, 1), scheduler.threads[0].wait_count);
    try scheduler.advance(&cpu);
    try std.testing.expectEqual(State.ready, scheduler.threads[0].state);
    try std.testing.expectEqual(@as(u7, 0), scheduler.threads[0].wait_count);
    scheduler.ticks = std.math.maxInt(u64);
    scheduler.sleep(std.math.maxInt(i64));
    try scheduler.advance(&cpu);
    try std.testing.expectEqual(std.math.maxInt(u64), scheduler.ticks);
}
