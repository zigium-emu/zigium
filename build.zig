const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.addModule("zigium", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli = b.addExecutable(.{
        .name = "zigium",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontend/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigium", .module = core }},
        }),
    });
    b.installArtifact(cli);
    const run = b.addRunArtifact(cli);
    run.addPassthruArgs();
    b.step("run", "Run an NRO").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run core tests").dependOn(&b.addRunArtifact(tests).step);
    const demo = b.addRunArtifact(cli);
    demo.addArg("--demo");
    b.step("demo", "Run the original hello NRO").dependOn(&demo.step);
}
