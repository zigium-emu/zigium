const std = @import("std");
const zigium = @import("zigium");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        if (comptime build_options.vulkan) return @import("gui.zig").run(init, .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "--gui") or std.mem.eql(u8, args[1], "--gui-smoke")) {
        if (comptime build_options.vulkan) {
            var options: @import("gui.zig").Options = .{};
            var cursor: usize = 2;
            if (std.mem.eql(u8, args[1], "--gui-smoke")) {
                if (cursor >= args.len) return error.InvalidArguments;
                options.smoke_frames = try std.fmt.parseInt(u32, args[cursor], 10);
                if (options.smoke_frames.? == 0 or options.smoke_frames.? > 3600) return error.InvalidArguments;
                cursor += 1;
            }
            while (cursor < args.len) : (cursor += 1) {
                if (std.mem.eql(u8, args[cursor], "--screenshot")) {
                    cursor += 1;
                    if (cursor >= args.len) return error.InvalidArguments;
                    options.screenshot = args[cursor];
                } else if (std.mem.eql(u8, args[cursor], "--trace")) options.trace = true else {
                    if (options.path != null or std.mem.startsWith(u8, args[cursor], "--")) return error.InvalidArguments;
                    options.path = args[cursor];
                }
            }
            return @import("gui.zig").run(init, options);
        } else return error.VulkanFrontendDisabled;
    }
    if (std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Zigium 0.1.0\nUsage: zigium <app.nro|app.nso> [--max-instructions N] [--trace]\n       zigium --gui [app.nro] [--trace]\n       zigium --gui-smoke N [app.nro] [--screenshot output.png]\n       zigium --demo\n       zigium --emit-demo <output.nro>\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "--emit-demo")) {
        if (args.len != 3) return error.InvalidArguments;
        const image = try zigium.demo.hello(allocator);
        defer allocator.free(image);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = image });
        return;
    }
    var budget: u64 = 10_000_000;
    var trace = false;
    var cursor: usize = 2;
    while (cursor < args.len) : (cursor += 1) {
        if (std.mem.eql(u8, args[cursor], "--max-instructions")) {
            cursor += 1;
            if (cursor >= args.len) return error.InvalidArguments;
            budget = try std.fmt.parseInt(u64, args[cursor], 10);
        } else if (std.mem.eql(u8, args[cursor], "--trace")) trace = true else return error.InvalidArguments;
    }
    const image = if (std.mem.eql(u8, args[1], "--demo")) try zigium.demo.hello(allocator) else try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(image);
    var machine = try zigium.Machine.init(allocator, image);
    defer machine.deinit();
    machine.kernel.services.trace = trace;
    machine.run(budget) catch |err| {
        const pc = machine.cpu.last_pc;
        const instruction = machine.cpu.last_instruction;
        std.debug.print("Guest stopped: {s}; PC=0x{x}, instruction=0x{x:0>8}, SVC=0x{x}, steps={d}\n", .{ @errorName(err), pc, instruction, machine.kernel.last_svc, machine.instructions });
        const services = &machine.kernel.services;
        std.debug.print("Last failing IPC: {s} command={d}, result=0x{x}, requests={d}\n", .{ @tagName(services.last_failure_session), services.last_failure_command, services.last_failure_result, services.request_count });
        if (services.last_nv_error != 0) std.debug.print("Last NV ioctl: 0x{x}, result={d}\n", .{ services.last_ioctl, services.last_nv_error });
        std.debug.print("X0=0x{x} X1=0x{x} X2=0x{x} TLS=0x{x}\n", .{ machine.cpu.x[0], machine.cpu.x[1], machine.cpu.x[2], machine.cpu.tpidrro_el0 });
        return err;
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, machine.kernel.debug_output.items);
    std.debug.print("Guest exited: {d}; instructions={d}, SVCs={d}\n", .{ machine.kernel.exit_code, machine.instructions, machine.kernel.svc_count });
    if (machine.kernel.exit_code != 0) return error.GuestExitFailure;
}
