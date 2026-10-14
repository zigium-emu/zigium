const std = @import("std");
const c = @import("vulkan_c");
const Renderer = @import("renderer").Renderer;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const instance = c.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigiumVulkanSmoke");
    var window_class = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = c.DefWindowProcW;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    if (c.RegisterClassW(&window_class) == 0) return error.WindowClass;
    defer _ = c.UnregisterClassW(class_name, instance);
    const width: u32 = 96;
    const height: u32 = 64;
    const window = c.CreateWindowExW(0, class_name, class_name, c.WS_POPUP, 0, 0, width, height, null, null, instance, null) orelse return error.WindowCreation;
    defer _ = c.DestroyWindow(window);
    _ = c.ShowWindow(window, c.SW_HIDE);
    var renderer = try Renderer.init(allocator, @intFromPtr(instance), @intFromPtr(window), width, height);
    defer renderer.deinit();
    try verifyFrame(&renderer, allocator, width, height);
    try renderer.resize(0, 0);
    if (renderer.width != 0 or renderer.height != 0) return error.ZeroExtentNotPaused;
    try renderer.present(&.{}, 0, 0);
    const resized_width: u32 = 128;
    const resized_height: u32 = 72;
    if (c.SetWindowPos(window, null, 0, 0, resized_width, resized_height, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return error.WindowResize;
    try renderer.resize(resized_width, resized_height);
    try verifyFrame(&renderer, allocator, resized_width, resized_height);
    try verifyFrame(&renderer, allocator, resized_width, resized_height);
    std.debug.print("Vulkan readback verified: initial {d}x{d}, resized {d}x{d}, zero extent paused, {d} presented frame(s), device={s}\n", .{ width, height, resized_width, resized_height, renderer.frames, std.mem.sliceTo(&renderer.device_name, 0) });
}

fn verifyFrame(renderer: *Renderer, allocator: std.mem.Allocator, width: u32, height: u32) !void {
    if (renderer.width != width or renderer.height != height) return error.UnexpectedSurfaceExtent;
    const pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, index| {
        const x = index % width;
        const y = index / width;
        pixel.* = if (((x / 8) ^ (y / 8)) & 1 == 0) 0xff16c6d4 else 0xff6d5dfc;
    }
    const previous_frames = renderer.frames;
    for (0..3) |_| {
        try renderer.present(pixels, width, height);
        if (renderer.frames != previous_frames) break;
    }
    if (renderer.frames == previous_frames) return error.NoPresentedFrame;
    const captured = try renderer.readback(allocator);
    defer allocator.free(captured);
    if (captured.len != pixels.len * 4) return error.ReadbackSize;
    for (pixels, 0..) |expected, index| {
        if (std.mem.readInt(u32, captured[index * 4 ..][0..4], .little) != expected) return error.ReadbackMismatch;
    }
}
