const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vulkan_enabled = b.option(bool, "vulkan", "Build the Windows Vulkan frontend") orelse (target.result.os.tag == .windows);
    const options = b.addOptions();
    options.addOption(bool, "vulkan", vulkan_enabled);
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
    cli.root_module.addOptions("build_options", options);
    if (vulkan_enabled) {
        if (target.result.os.tag != .windows) @panic("The Vulkan frontend currently supports Windows; use -Dvulkan=false for the core CLI");
        const sdk = b.option([]const u8, "vulkan-sdk", "Vulkan SDK directory") orelse b.graph.environ_map.get("VULKAN_SDK") orelse @panic("Set VULKAN_SDK or pass -Dvulkan-sdk=<directory>");
        const translation = b.addTranslateC(.{ .root_source_file = b.path("src/vulkan/headers.h"), .target = target, .optimize = optimize });
        translation.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        const bindings = translation.createModule();
        bindings.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Lib" }) });
        bindings.linkSystemLibrary("vulkan-1", .{});
        bindings.linkSystemLibrary("user32", .{});
        bindings.linkSystemLibrary("kernel32", .{});
        const renderer = b.createModule(.{
            .root_source_file = b.path("src/vulkan/renderer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vulkan_c", .module = bindings }},
        });
        cli.root_module.addImport("renderer", renderer);
        cli.root_module.addImport("vulkan_c", bindings);
        cli.root_module.linkSystemLibrary("comdlg32", .{});
        cli.root_module.linkSystemLibrary("shell32", .{});
        const gui = b.addRunArtifact(cli);
        gui.addArg("--gui");
        gui.addPassthruArgs();
        b.step("gui", "Launch the Vulkan library frontend").dependOn(&gui.step);
        const smoke = b.addExecutable(.{
            .name = "zigium-vulkan-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/vulkan_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "renderer", .module = renderer }, .{ .name = "vulkan_c", .module = bindings } },
            }),
        });
        b.step("vulkan-smoke-build", "Compile the hidden-window Vulkan readback check").dependOn(&smoke.step);
        b.step("vulkan-smoke", "Validate GPU image transfer through Vulkan readback").dependOn(&b.addRunArtifact(smoke).step);
    }
    b.installArtifact(cli);
    const run = b.addRunArtifact(cli);
    run.addPassthruArgs();
    b.step("run", "Run an NRO").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run core tests").dependOn(&b.addRunArtifact(tests).step);
    const demo = b.addRunArtifact(cli);
    demo.addArg("--demo");
    b.step("demo", "Run the original hello NRO").dependOn(&demo.step);
    const generator_core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const generator = b.addExecutable(.{
        .name = "zigium-make-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/make_demo.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigium", .module = generator_core }},
        }),
    });
    const emit = b.addRunArtifact(generator);
    const service_demo_path = emit.addOutputFileArg("hello-services.nro");
    const install_demo = b.addInstallFile(service_demo_path, "hello-services.nro");
    b.step("make-demo", "Generate the original SM/APM homebrew NRO").dependOn(&install_demo.step);
    const services_demo = b.addRunArtifact(cli);
    services_demo.addFileArg(service_demo_path);
    b.step("services-demo", "Run the original service NRO end to end").dependOn(&services_demo.step);
}
