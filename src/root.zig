const std = @import("std");

pub const Memory = @import("memory/address_space.zig").Memory;
pub const Cpu = @import("cpu/aarch64.zig").Cpu;
pub const Kernel = @import("kernel/kernel.zig").Kernel;
pub const Services = @import("kernel/services.zig").Services;
pub const nro = @import("loader/nro.zig");
pub const nso = @import("loader/nso.zig");
pub const homebrew = @import("loader/homebrew.zig");
pub const demo = @import("loader/demo.zig");
pub const framebuffer = @import("gpu/framebuffer.zig");

pub const Machine = struct {
    memory: Memory,
    cpu: Cpu,
    kernel: Kernel,
    halted: bool = false,
    blocked: bool = false,
    instructions: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, image: []const u8) !Machine {
        var memory = Memory.init(allocator);
        errdefer memory.deinit();
        const is_nso = image.len >= 4 and std.mem.eql(u8, image[0..4], "NSO0");
        const loaded = if (is_nso) try nso.load(&memory, image) else try nro.load(&memory, image);
        const environment = try homebrew.setup(&memory);
        var cpu: Cpu = .{ .pc = loaded.entry, .sp = environment.stack_top, .tpidrro_el0 = environment.tls, .tpidr_el0 = environment.tls };
        cpu.x[0] = if (is_nso) 0 else environment.config;
        cpu.x[1] = if (is_nso) homebrew.main_thread_handle else homebrew.entry_x1;
        cpu.x[30] = homebrew.entry_lr;
        var kernel = Kernel.init(allocator);
        kernel.scheduler = @import("kernel/scheduler.zig").Scheduler.init(cpu);
        return .{ .memory = memory, .cpu = cpu, .kernel = kernel };
    }

    pub fn deinit(self: *Machine) void {
        self.kernel.deinit();
        self.memory.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Machine, instruction_budget: u64) !void {
        if (!try self.tick(instruction_budget)) return if (self.blocked) error.GuestWaiting else error.InstructionBudgetExceeded;
    }

    pub fn tick(self: *Machine, instruction_budget: u64) !bool {
        self.kernel.pollWaiters();
        if (self.blocked) {
            self.kernel.scheduler.activateReady(&self.cpu) catch return false;
            self.blocked = false;
        }
        var remaining = instruction_budget;
        while (!self.halted and remaining != 0) : (remaining -= 1) {
            const event = try self.cpu.step(&self.memory);
            self.instructions += 1;
            switch (event) {
                .next => {},
                .svc => |id| self.halted = try self.kernel.dispatch(&self.cpu, &self.memory, id) == .exited,
                .brk => return error.GuestBreakpoint,
            }
            if (!self.halted) self.kernel.scheduler.advance(&self.cpu) catch {
                self.blocked = true;
                return false;
            };
        }
        return self.halted;
    }
};

test "hello NRO runs through CPU, guest ABI and kernel" {
    const image = try demo.hello(std.testing.allocator);
    defer std.testing.allocator.free(image);
    var machine = try Machine.init(std.testing.allocator, image);
    defer machine.deinit();
    try std.testing.expectEqual(homebrew.config_base, machine.cpu.x[0]);
    try std.testing.expectEqual(homebrew.entry_x1, machine.cpu.x[1]);
    try machine.run(1000);
    try std.testing.expect(machine.halted);
    try std.testing.expectEqualStrings(demo.message, machine.kernel.debug_output.items);
    try std.testing.expectEqual(@as(u64, 2), machine.kernel.svc_count);
}

test "original service NRO initializes SM and APM through guest CMIF" {
    const image = try demo.services(std.testing.allocator);
    defer std.testing.allocator.free(image);
    var machine = try Machine.init(std.testing.allocator, image);
    defer machine.deinit();
    try machine.run(10_000);
    try std.testing.expectEqual(@as(u64, 0), machine.kernel.exit_code);
    try std.testing.expectEqual(@as(u64, 3), machine.kernel.services.request_count);
    try std.testing.expectEqual(@as(u64, 6), machine.kernel.svc_count);
    try std.testing.expect(machine.kernel.services.registered);
    try std.testing.expectEqualStrings(demo.service_message, machine.kernel.debug_output.items);
}

test "instruction budget bounds a guest infinite loop" {
    const image = try demo.hello(std.testing.allocator);
    defer std.testing.allocator.free(image);
    std.mem.writeInt(u32, image[0..4], 0x14000000, .little);
    var machine = try Machine.init(std.testing.allocator, image);
    defer machine.deinit();
    try std.testing.expectError(error.InstructionBudgetExceeded, machine.run(10));
    try std.testing.expectEqual(@as(u64, 10), machine.instructions);
}

test "guest wait yields to host and resumes at next instruction after signal" {
    const image = try demo.hello(std.testing.allocator);
    defer std.testing.allocator.free(image);
    std.mem.writeInt(u32, image[0x80..0x84], 0xd4000301, .little);
    std.mem.writeInt(u32, image[0x84..0x88], 0xd40000e1, .little);
    var machine = try Machine.init(std.testing.allocator, image);
    defer machine.deinit();
    const event = try machine.kernel.services.createEvent(false);
    try machine.memory.writeInt(u32, homebrew.heap_base, event);
    machine.cpu.pc = nro.base + 0x80;
    machine.cpu.x[1] = homebrew.heap_base;
    machine.cpu.x[2] = 1;
    machine.cpu.x[3] = std.math.maxInt(u64);
    try std.testing.expect(!try machine.tick(1000));
    try std.testing.expect(machine.blocked);
    try std.testing.expectEqual(@as(u64, 1), machine.instructions);
    try std.testing.expect(!try machine.tick(1000));
    try std.testing.expectEqual(@as(u64, 1), machine.instructions);
    try machine.kernel.services.signalEvent(event);
    try std.testing.expect(try machine.tick(1000));
    try std.testing.expectEqual(@as(u64, 0), machine.kernel.exit_code);
    try std.testing.expectEqual(@as(u64, 2), machine.instructions);
}

test {
    std.testing.refAllDecls(@This());
}
