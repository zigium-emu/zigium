const std = @import("std");
const zigium = @import("zigium");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Zigium 0.1.0\nUsage: zigium <app.nro> [--max-instructions N]\n       zigium --demo\n       zigium --emit-demo <output.nro>\n", .{});
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
    if (args.len > 2) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--max-instructions")) return error.InvalidArguments;
        budget = try std.fmt.parseInt(u64, args[3], 10);
    }
    const image = if (std.mem.eql(u8, args[1], "--demo")) try zigium.demo.hello(allocator) else try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(image);
    var machine = try zigium.Machine.init(allocator, image);
    defer machine.deinit();
    machine.run(budget) catch |err| {
        const pc = machine.cpu.last_pc;
        const instruction = machine.cpu.last_instruction;
        std.debug.print("Guest stopped: {s}; PC=0x{x}, instruction=0x{x:0>8}, SVC=0x{x}, steps={d}\n", .{ @errorName(err), pc, instruction, machine.kernel.last_svc, machine.instructions });
        return err;
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, machine.kernel.debug_output.items);
    std.debug.print("Guest exited: {d}; instructions={d}, SVCs={d}\n", .{ machine.kernel.exit_code, machine.instructions, machine.kernel.svc_count });
    if (machine.kernel.exit_code != 0) return error.GuestExitFailure;
}
