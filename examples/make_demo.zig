const std = @import("std");
const zigium = @import("zigium");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputPath;
    const image = try zigium.demo.services(init.gpa);
    defer init.gpa.free(image);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = image });
}
