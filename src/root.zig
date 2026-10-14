const std = @import("std");

pub const Memory = @import("memory/address_space.zig").Memory;
pub const Cpu = @import("cpu/aarch64.zig").Cpu;
pub const Kernel = @import("kernel/kernel.zig").Kernel;
pub const nro = @import("loader/nro.zig");
pub const nso = @import("loader/nso.zig");
pub const homebrew = @import("loader/homebrew.zig");
pub const demo = @import("loader/demo.zig");

pub const Machine = struct {
    memory: Memory,
    cpu: Cpu,
    kernel: Kernel,
    halted: bool = false,
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
        var remaining = instruction_budget;
        while (!self.halted and remaining != 0) : (remaining -= 1) {
            const event = try self.cpu.step(&self.memory);
            self.instructions += 1;
            switch (event) {
                .next => {},
                .svc => |id| self.halted = try self.kernel.dispatch(&self.cpu, &self.memory, id) == .exited,
                .brk => return error.GuestBreakpoint,
            }
            if (!self.halted) try self.kernel.scheduler.advance(&self.cpu);
        }
        if (!self.halted) return error.InstructionBudgetExceeded;
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

test "instruction budget bounds a guest infinite loop" {
    const image = try demo.hello(std.testing.allocator);
    defer std.testing.allocator.free(image);
    std.mem.writeInt(u32, image[0..4], 0x14000000, .little);
    var machine = try Machine.init(std.testing.allocator, image);
    defer machine.deinit();
    try std.testing.expectError(error.InstructionBudgetExceeded, machine.run(10));
    try std.testing.expectEqual(@as(u64, 10), machine.instructions);
}

test {
    std.testing.refAllDecls(@This());
}
