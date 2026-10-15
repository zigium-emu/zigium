const std = @import("std");
const zigium = @import("zigium");
const c = @import("vulkan_c");
const Renderer = @import("renderer").Renderer;
const Window = @import("window.zig").Window;
const drawing = @import("canvas.zig");
const Canvas = drawing.Canvas;
const Rect = drawing.Rect;

pub const Options = struct {
    path: ?[]const u8 = null,
    smoke_frames: ?u32 = null,
    screenshot: ?[]const u8 = null,
    trace: bool = false,
    input_smoke: bool = false,
};

const color = struct {
    const background = 0xff111819;
    const sidebar = 0xff171f20;
    const panel = 0xff1c2829;
    const border = 0xff304042;
    const muted = 0xff829695;
    const text = 0xffedf4ef;
    const orange = 0xffffac7e;
    const mint = 0xff93e5c1;
    const black = 0xff0c1213;
};
const Status = enum { ready, running, paused, exited, stopped };
const Item = struct { path: ?[]u8, title: []u8 };

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    trace: bool,
    library: std.ArrayList(Item) = .empty,
    selected: usize = 0,
    machine: ?zigium.Machine = null,
    status: Status = .ready,
    failure: ?anyerror = null,
    guest_pixels: []u32 = &.{},
    guest_width: u32 = 0,
    guest_height: u32 = 0,
    frame_sequence: u64 = 0,
    guest_fps: ?f64 = null,
    fps_sequence: u64 = 0,
    fps_tick: i64 = 0,
    clock_frequency: i64,

    fn deinit(self: *App) void {
        if (self.machine) |*machine| machine.deinit();
        for (self.library.items) |item| {
            if (item.path) |path| self.allocator.free(path);
            self.allocator.free(item.title);
        }
        self.library.deinit(self.allocator);
        self.allocator.free(self.guest_pixels);
    }

    fn addFile(self: *App, path: []const u8) !usize {
        for (self.library.items, 0..) |item, index| {
            if (item.path) |existing| if (std.ascii.eqlIgnoreCase(existing, path)) return index;
        }
        if (self.library.items.len >= 16) return error.LibraryFull;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const title = try self.allocator.dupe(u8, std.fs.path.stem(std.fs.path.basename(path)));
        errdefer self.allocator.free(title);
        try self.library.append(self.allocator, .{ .path = owned_path, .title = title });
        return self.library.items.len - 1;
    }

    fn boot(self: *App, index: usize) !void {
        if (self.machine) |*machine| machine.deinit();
        self.machine = null;
        self.allocator.free(self.guest_pixels);
        self.guest_pixels = &.{};
        self.guest_width = 0;
        self.guest_height = 0;
        self.frame_sequence = 0;
        self.guest_fps = null;
        self.fps_sequence = 0;
        self.fps_tick = clock();
        self.selected = index;
        self.failure = null;
        self.status = .running;
        const image = if (self.library.items[index].path) |path|
            try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024 * 1024))
        else
            try zigium.demo.hello(self.allocator);
        defer self.allocator.free(image);
        self.machine = try zigium.Machine.init(self.allocator, image);
        self.machine.?.kernel.services.trace = self.trace;
    }

    fn stop(self: *App, failure: anyerror) void {
        self.status = .stopped;
        self.failure = failure;
        self.guest_fps = null;
        if (self.machine) |*machine| {
            std.debug.print("GUI guest stopped: {s}; PC=0x{x}, instruction=0x{x:0>8}, steps={d}\n", .{ @errorName(failure), machine.cpu.last_pc, machine.cpu.last_instruction, machine.instructions });
            const services = &machine.kernel.services;
            if (services.last_failure_result != 0) std.debug.print("Last failing IPC: {s} command={d}, result=0x{x}\n", .{ @tagName(services.last_failure_session), services.last_failure_command, services.last_failure_result });
            if (services.last_nv_error != 0) std.debug.print("Last NV ioctl: 0x{x}, result={d}\n", .{ services.last_ioctl, services.last_nv_error });
        }
    }

    fn advance(self: *App, window: *const Window) !void {
        const machine = if (self.machine) |*machine| machine else return;
        const input = buttons(window);
        var controller: zigium.hid.Input = .{ .buttons = input.buttons, .left_x = input.x, .left_y = input.y, .right_x = input.rx, .right_y = input.ry };
        if (self.guestRect(window.width, window.height)) |rect| {
            if (window.mouse_held and rect.contains(window.mouse_x, window.mouse_y)) {
                controller.touch = .{
                    .x = @intCast(@as(u64, @intCast(window.mouse_x - rect.x)) * 1280 / rect.width),
                    .y = @intCast(@as(u64, @intCast(window.mouse_y - rect.y)) * 720 / rect.height),
                };
            }
        }
        try machine.kernel.services.updateControllerInput(&machine.memory, controller);
        machine.kernel.services.signalVsync();
        if (self.status != .running) return;
        if (try machine.runToFrame(2_000_000)) {
            self.status = .exited;
            std.debug.print("GUI guest exited: {d}; instructions={d}, SVCs={d}\n", .{ machine.kernel.exit_code, machine.instructions, machine.kernel.svc_count });
        }
        if (machine.kernel.services.latest_frame) |frame| {
            if (frame.sequence != self.frame_sequence) {
                if (frame.format != 1 or frame.block_height_log2 > 7) return error.UnsupportedFramebufferFormat;
                const count = try std.math.mul(usize, frame.width, frame.height);
                if (count > 4096 * 4096) return error.InvalidFramebuffer;
                if (self.guest_pixels.len != count) {
                    const pixels = try self.allocator.alloc(u32, count);
                    self.allocator.free(self.guest_pixels);
                    self.guest_pixels = pixels;
                }
                try zigium.framebuffer.decode(&machine.memory, self.allocator, .{
                    .address = frame.cpu_address,
                    .byte_length = frame.byte_length,
                    .width = frame.width,
                    .height = frame.height,
                    .stride = frame.stride,
                    .block_height_log2 = @intCast(frame.block_height_log2),
                    .flip_h = frame.flip_h,
                    .flip_v = frame.flip_v,
                }, self.guest_pixels);
                self.guest_width = frame.width;
                self.guest_height = frame.height;
                self.frame_sequence = frame.sequence;
            }
        }
        const now = clock();
        if (now - self.fps_tick >= self.clock_frequency) {
            if (self.frame_sequence != 0) self.guest_fps = @as(f64, @floatFromInt(self.frame_sequence - self.fps_sequence)) * @as(f64, @floatFromInt(self.clock_frequency)) / @as(f64, @floatFromInt(now - self.fps_tick));
            self.fps_tick = now;
            self.fps_sequence = self.frame_sequence;
        }
    }

    fn action(self: *App, window: *Window, bounds: Rect) void {
        if (window.clicked and bounds.contains(window.mouse_x, window.mouse_y)) {
            self.toggle();
            window.clicked = false;
        }
    }

    fn guestRect(self: *const App, width: u32, height: u32) ?Rect {
        if (self.guest_pixels.len == 0 or self.guest_width == 0 or self.guest_height == 0) return null;
        const sidebar: u32 = if (width < 900) 220 else 260;
        const view: Rect = .{ .x = @intCast(sidebar + 32), .y = 114, .width = width -| (sidebar + 64), .height = height -| 345 };
        if (view.width == 0 or view.height == 0) return null;
        const factor = @min(@as(f64, @floatFromInt(view.width)) / @as(f64, @floatFromInt(self.guest_width)), @as(f64, @floatFromInt(view.height)) / @as(f64, @floatFromInt(self.guest_height)));
        const image_width: u32 = @intFromFloat(@as(f64, @floatFromInt(self.guest_width)) * factor);
        const image_height: u32 = @intFromFloat(@as(f64, @floatFromInt(self.guest_height)) * factor);
        if (image_width == 0 or image_height == 0) return null;
        return .{ .x = view.x + @as(i32, @intCast((view.width - image_width) / 2)), .y = view.y + @as(i32, @intCast((view.height - image_height) / 2)), .width = image_width, .height = image_height };
    }

    fn toggle(self: *App) void {
        switch (self.status) {
            .running => {
                self.status = .paused;
                self.guest_fps = null;
            },
            .paused => {
                self.status = .running;
                self.fps_tick = clock();
                self.fps_sequence = self.frame_sequence;
            },
            else => self.boot(self.selected) catch |err| self.stop(err),
        }
    }

    fn draw(self: *App, canvas: *Canvas, window: *Window, renderer: *const Renderer) void {
        canvas.clear(color.background);
        const sidebar: u32 = if (canvas.width < 900) 220 else 260;
        canvas.rectangle(.{ .x = 0, .y = 0, .width = sidebar, .height = canvas.height }, color.sidebar);
        canvas.rectangle(.{ .x = @intCast(sidebar), .y = 0, .width = 1, .height = canvas.height }, color.border);
        canvas.rounded(.{ .x = 24, .y = 26, .width = 48, .height = 48 }, 12, color.orange);
        canvas.text(33, 34, "Z", 5, color.background);
        canvas.text(89, 32, "ZIGIUM", 3, color.text);
        canvas.text(90, 62, "HOME BREW. NEXT.", 1, color.muted);
        canvas.text(24, 117, "YOUR LIBRARY", 2, color.muted);
        const open: Rect = .{ .x = 16, .y = 152, .width = sidebar - 32, .height = 64 };
        canvas.rounded(open, 10, if (open.contains(window.mouse_x, window.mouse_y)) 0xff344744 else color.panel);
        canvas.text(31, 168, "+ OPEN HOMEBREW", 2, color.mint);
        canvas.text(32, 193, "CTRL+O  /  NRO + NSO", 1, color.muted);
        for (self.library.items, 0..) |item, index| {
            const row: Rect = .{ .x = 16, .y = @intCast(242 + index * 72), .width = sidebar - 32, .height = 60 };
            if (row.y + 80 >= canvas.height) break;
            const selected = self.machine != null and index == self.selected;
            canvas.rounded(row, 8, if (selected) 0xff303936 else if (row.contains(window.mouse_x, window.mouse_y)) color.panel else color.sidebar);
            if (selected) canvas.rectangle(.{ .x = row.x, .y = row.y + 12, .width = 3, .height = 36 }, color.orange);
            canvas.text(row.x + 16, row.y + 13, item.title[0..@min(item.title.len, (sidebar - 60) / 12)], 2, color.text);
            canvas.text(row.x + 16, row.y + 37, if (item.path == null) "ORIGINAL ZIGIUM DEMO" else "LOCAL HOMEBREW", 1, color.muted);
            if (window.clicked and row.contains(window.mouse_x, window.mouse_y)) {
                self.boot(index) catch |err| self.stop(err);
                window.clicked = false;
            }
        }
        canvas.text(24, @as(i32, @intCast(canvas.height)) - 73, "VULKAN ONLY", 2, color.mint);
        canvas.text(24, @as(i32, @intCast(canvas.height)) - 45, "A CLEAN START FOR NX.", 1, color.muted);
        const left: i32 = @intCast(sidebar + 32);
        const content_width = canvas.width -| (sidebar + 64);
        canvas.text(left, 31, "HOME BREW, AT HOME.", if (content_width > 600) 3 else 2, color.text);
        canvas.text(left, 66, "SMALL APPS. BIG POSSIBILITIES.", 1, color.muted);
        const button: Rect = .{ .x = @as(i32, @intCast(canvas.width)) - 142, .y = 30, .width = 108, .height = 42 };
        canvas.rounded(button, 8, color.orange);
        canvas.text(button.x + 18, button.y + 14, if (self.status == .running) "PAUSE" else if (self.status == .paused) "RESUME" else "START", 2, color.background);
        self.action(window, button);
        const view: Rect = .{ .x = left, .y = 114, .width = content_width, .height = canvas.height -| 345 };
        canvas.rounded(.{ .x = view.x - 1, .y = view.y - 1, .width = view.width + 2, .height = view.height + 2 }, 13, color.border);
        canvas.rounded(view, 12, color.black);
        if (self.guestRect(canvas.width, canvas.height)) |rect| {
            canvas.image(self.guest_pixels, self.guest_width, self.guest_height, rect);
        } else {
            const cx = view.x + @as(i32, @intCast(view.width / 2));
            const cy = view.y + @as(i32, @intCast(view.height / 2));
            canvas.text(cx - 18, cy - 85, "Z", 7, color.mint);
            const title = if (self.status == .ready) "READY WHEN YOU ARE." else if (self.status == .stopped) "BOOT STOPPED." else if (self.status == .exited and self.library.items[self.selected].path == null) "HELLO, ZIGIUM." else if (self.status == .exited) "APPLICATION EXITED." else "BOOTING HOMEBREW...";
            const scale: u32 = if (view.width > 620) 3 else 2;
            canvas.text(cx - @as(i32, @intCast(title.len * 6 * scale / 2)), cy + 4, title, scale, if (self.status == .stopped) color.orange else color.text);
            const subtitle = if (self.failure) |err| @errorName(err) else if (self.status == .ready) "OPEN AN APP OR TRY HELLO WORLD." else if (self.status == .exited) "CPU + HORIZON SERVICES + VULKAN" else "WAITING FOR THE FIRST GUEST FRAME.";
            canvas.text(cx - @as(i32, @intCast(subtitle.len * 3)), cy + 44, subtitle, 1, color.muted);
        }
        const strip_y: i32 = @intCast(view.y + @as(i32, @intCast(view.height)) + 20);
        canvas.text(left, strip_y, @tagName(self.status), 2, if (self.status == .stopped) color.orange else color.mint);
        var line: [256]u8 = undefined;
        const frames = std.fmt.bufPrint(&line, "GUEST FRAMES {d}   /   VULKAN PRESENTS {d}", .{ self.frame_sequence, renderer.frames }) catch "";
        canvas.text(left + 160, strip_y + 3, frames, 1, color.muted);
        if (self.failure) |failure| canvas.text(left, strip_y + 26, @errorName(failure), 1, color.orange);
        const diagnostics_y: i32 = @intCast(canvas.height -| 170);
        canvas.rounded(.{ .x = left, .y = diagnostics_y, .width = content_width, .height = 112 }, 10, color.panel);
        canvas.text(left + 16, diagnostics_y + 16, "RUNTIME", 1, color.mint);
        if (self.machine) |*machine| {
            const stats = std.fmt.bufPrint(&line, "{d} INSTRUCTIONS   {d} SVCS   {d} IPC REQUESTS", .{ machine.instructions, machine.kernel.svc_count, machine.kernel.services.request_count }) catch "";
            canvas.text(left + 16, diagnostics_y + 38, stats, 1, color.text);
            const pc = std.fmt.bufPrint(&line, "PC 0X{X}   INSTRUCTION 0X{X:0>8}   EXIT {d}", .{ machine.cpu.last_pc, machine.cpu.last_instruction, machine.kernel.exit_code }) catch "";
            canvas.text(left + 16, diagnostics_y + 60, pc, 1, color.muted);
            const output = machine.kernel.debug_output.items;
            if (output.len != 0) {
                const end = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
                canvas.text(left + 16, diagnostics_y + 83, output[0..@min(end, content_width / 6 -| 6)], 1, color.mint);
            } else if (self.status == .stopped and machine.kernel.services.last_failure_result != 0) {
                const failure = std.fmt.bufPrint(&line, "IPC {s} CMD {d} RESULT 0X{X}", .{ @tagName(machine.kernel.services.last_failure_session), machine.kernel.services.last_failure_command, machine.kernel.services.last_failure_result }) catch "";
                canvas.text(left + 16, diagnostics_y + 83, failure, 1, color.orange);
            } else canvas.text(left + 16, diagnostics_y + 83, "GUEST LOG IS QUIET.", 1, color.muted);
        } else canvas.text(left + 16, diagnostics_y + 48, "F1 HELLO WORLD   /   CTRL+O OPEN HOMEBREW", 1, color.muted);
        canvas.text(left, @as(i32, @intCast(canvas.height)) - 31, "WASD MOVE   IJKL AIM   HOLD MOUSE FIRE   SPACE A   Z B   F5 PAUSE", 1, color.muted);
        if (self.guest_fps) |fps| {
            const value = std.fmt.bufPrint(&line, "{d:.1} GUEST FPS", .{fps}) catch "";
            canvas.text(@as(i32, @intCast(canvas.width)) - 140, strip_y + 28, value, 1, color.mint);
        }
    }
};

fn clock() i64 {
    var value: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&value);
    return value.QuadPart;
}

const Input = struct { buttons: u64, x: i32, y: i32, rx: i32 = 0, ry: i32 = 0 };
fn buttons(window: *const Window) Input {
    var input: Input = .{ .buttons = 0, .x = 0, .y = 0 };
    if (window.keys['X'] or window.keys[c.VK_SPACE]) input.buttons |= 1;
    if (window.keys['Z']) input.buttons |= 2;
    if (window.keys[c.VK_RETURN]) input.buttons |= 1 << 10;
    if (window.keys[c.VK_ESCAPE]) input.buttons |= 1 << 11;
    if (window.keys[c.VK_LEFT]) input.buttons |= 1 << 12;
    if (window.keys[c.VK_UP]) input.buttons |= 1 << 13;
    if (window.keys[c.VK_RIGHT]) input.buttons |= 1 << 14;
    if (window.keys[c.VK_DOWN]) input.buttons |= 1 << 15;
    if (window.keys['A'] or window.keys[c.VK_LEFT]) input.x -= 32767;
    if (window.keys['D'] or window.keys[c.VK_RIGHT]) input.x += 32767;
    if (window.keys['W'] or window.keys[c.VK_UP]) input.y += 32767;
    if (window.keys['S'] or window.keys[c.VK_DOWN]) input.y -= 32767;
    if (window.keys['J']) input.rx -= 32767;
    if (window.keys['L']) input.rx += 32767;
    if (window.keys['I']) input.ry += 32767;
    if (window.keys['K']) input.ry -= 32767;
    return input;
}

const InputProbe = struct {
    const Stage = enum { title, focus, start, move, prime, neutral, fire, touch, sustained, done };
    stage: Stage = .title,
    held_key: ?u8 = null,
    held_secondary: ?u8 = null,
    held_mouse: bool = false,
    started: i64,
    stage_tick: i64 = 0,
    previous_sequence: u64 = 0,
    previous_hash: u64 = 0,
    gameplay_tick: i64 = 0,
    gameplay_sequence: u64 = 0,
    key_seen: bool = false,

    fn release(self: *InputProbe) void {
        if (self.held_key) |key| c.keybd_event(key, 0, c.KEYEVENTF_KEYUP, 0);
        if (self.held_secondary) |key| c.keybd_event(key, 0, c.KEYEVENTF_KEYUP, 0);
        if (self.held_mouse) c.mouse_event(c.MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        self.held_key = null;
        self.held_secondary = null;
        self.held_mouse = false;
    }

    fn press(self: *InputProbe, window: *Window, key: u8) !void {
        if (c.GetForegroundWindow() != window.handle) return error.InputSmokeNoForeground;
        self.release();
        self.held_key = key;
        self.key_seen = false;
        c.keybd_event(key, 0, 0, 0);
        std.debug.print("Input smoke OS key down: 0x{x}; foreground HWND=0x{x}\n", .{ key, @intFromPtr(window.handle) });
    }

    fn pressPair(self: *InputProbe, window: *Window, first: u8, second: u8) !void {
        try self.press(window, first);
        if (c.GetForegroundWindow() != window.handle) return error.InputSmokeNoForeground;
        self.held_secondary = second;
        c.keybd_event(second, 0, 0, 0);
        std.debug.print("Input smoke OS key down: 0x{x}; foreground HWND=0x{x}\n", .{ second, @intFromPtr(window.handle) });
    }

    fn focus(window: *Window) !void {
        _ = c.BringWindowToTop(window.handle);
        _ = c.SetForegroundWindow(window.handle);
        _ = c.SetFocus(window.handle);
        if (c.GetForegroundWindow() == window.handle) return;
        const sidebar: i32 = if (window.width < 900) 220 else 260;
        var point: c.POINT = .{
            .x = sidebar + 32 + @as(i32, @intCast((window.width -| @as(u32, @intCast(sidebar + 64))) / 2)),
            .y = 114 + @as(i32, @intCast((window.height -| 345) / 2)),
        };
        if (c.ClientToScreen(window.handle, &point) == 0) return error.InputSmokeScreenPoint;
        if (c.WindowFromPoint(point) != window.handle) return error.InputSmokeWindowObscured;
        if (c.SetCursorPos(point.x, point.y) == 0) return error.InputSmokeCursor;
        if (c.WindowFromPoint(point) != window.handle) return error.InputSmokeWindowObscured;
        c.mouse_event(c.MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        c.mouse_event(c.MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        std.debug.print("Input smoke OS click: screen ({d}, {d}); verified HWND=0x{x}\n", .{ point.x, point.y, @intFromPtr(window.handle) });
    }

    fn pressTouch(self: *InputProbe, app: *const App, window: *Window) !void {
        if (c.GetForegroundWindow() != window.handle) return error.InputSmokeNoForeground;
        self.release();
        const rect = app.guestRect(window.width, window.height) orelse return error.InputSmokeNoViewport;
        var point: c.POINT = .{ .x = rect.x + @as(i32, @intCast(rect.width * 3 / 4)), .y = rect.y + @as(i32, @intCast(rect.height / 4)) };
        if (c.ClientToScreen(window.handle, &point) == 0) return error.InputSmokeScreenPoint;
        if (c.WindowFromPoint(point) != window.handle) return error.InputSmokeWindowObscured;
        if (c.SetCursorPos(point.x, point.y) == 0) return error.InputSmokeCursor;
        if (c.WindowFromPoint(point) != window.handle) return error.InputSmokeWindowObscured;
        self.held_mouse = true;
        self.key_seen = false;
        c.mouse_event(c.MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        std.debug.print("Input smoke OS touch hold: screen ({d}, {d}); verified HWND=0x{x}\n", .{ point.x, point.y, @intFromPtr(window.handle) });
    }

    fn capture(app: *const App, renderer: *Renderer, prefix: []const u8, label: []const u8) !void {
        const base = if (std.mem.endsWith(u8, prefix, ".png")) prefix[0 .. prefix.len - 4] else prefix;
        const path = try std.fmt.allocPrint(app.allocator, "{s}-{s}.png", .{ base, label });
        defer app.allocator.free(path);
        const pixels = try renderer.readback(app.allocator);
        defer app.allocator.free(pixels);
        try drawing.writePng(app.io, app.allocator, path, pixels, renderer.width, renderer.height);
        std.debug.print("Input smoke GPU capture: {s}; guest sequence={d}\n", .{ path, app.frame_sequence });
    }

    fn advance(self: *InputProbe, app: *App, window: *Window, renderer: *Renderer, prefix: []const u8) !void {
        const now = clock();
        if (now - self.started > app.clock_frequency * 50) return error.InputSmokeTimeout;
        if (app.status == .stopped or app.status == .exited) {
            self.release();
            try capture(app, renderer, prefix, "stopped");
            return error.InputSmokeGuestStopped;
        }
        if (self.held_key) |key| {
            if (c.GetForegroundWindow() != window.handle) return error.InputSmokeFocusLost;
            if (!self.key_seen and window.keys[key] and (if (self.held_secondary) |second| window.keys[second] else true)) {
                self.key_seen = true;
                std.debug.print("Input smoke window received OS key: 0x{x}\n", .{key});
                if (self.held_secondary) |second| std.debug.print("Input smoke window received OS key: 0x{x}\n", .{second});
            }
            if (!self.key_seen and now - self.stage_tick > app.clock_frequency) return error.InputSmokeKeyNotReceived;
        }
        if (self.held_mouse) {
            if (c.GetForegroundWindow() != window.handle) return error.InputSmokeFocusLost;
            if (!self.key_seen and window.mouse_held) {
                self.key_seen = true;
                std.debug.print("Input smoke window received OS mouse hold\n", .{});
            }
            if (!self.key_seen and now - self.stage_tick > app.clock_frequency) return error.InputSmokeMouseNotReceived;
        }
        if (app.guest_pixels.len == 0) return;
        var nonblack = false;
        for (app.guest_pixels) |pixel| {
            if (pixel & 0x00ffffff != 0) {
                nonblack = true;
                break;
            }
        }
        if (!nonblack) return;
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(app.guest_pixels));
        const changed = app.frame_sequence > self.previous_sequence and hash != self.previous_hash;
        switch (self.stage) {
            .title => if (app.frame_sequence >= 5) {
                try capture(app, renderer, prefix, "title");
                self.previous_sequence = app.frame_sequence;
                self.previous_hash = hash;
                try focus(window);
                self.stage_tick = now;
                self.stage = .focus;
            },
            .focus => {
                if (c.GetForegroundWindow() != window.handle) {
                    if (now - self.stage_tick > app.clock_frequency) return error.InputSmokeNoForeground;
                    return;
                }
                try self.press(window, c.VK_SPACE);
                self.stage_tick = now;
                self.stage = .start;
            },
            .start => if (changed and now - self.stage_tick > @divTrunc(app.clock_frequency, 4)) {
                self.release();
                try capture(app, renderer, prefix, "gameplay");
                self.gameplay_tick = now;
                self.gameplay_sequence = app.frame_sequence;
                self.previous_sequence = app.frame_sequence;
                self.previous_hash = hash;
                try self.press(window, 'D');
                self.stage_tick = now;
                self.stage = .move;
            },
            .move => if (changed and now - self.stage_tick >= app.clock_frequency) {
                self.release();
                try capture(app, renderer, prefix, "movement");
                self.previous_sequence = app.frame_sequence;
                self.previous_hash = hash;
                try self.pressPair(window, 'I', 'L');
                self.stage_tick = now;
                self.stage = .prime;
            },
            .prime => if (self.key_seen and app.frame_sequence >= self.previous_sequence + 2) {
                self.release();
                self.previous_sequence = app.frame_sequence;
                self.stage_tick = now;
                self.stage = .neutral;
            },
            .neutral => if (!window.keys['I'] and !window.keys['L'] and app.frame_sequence >= self.previous_sequence + 2) {
                try self.pressPair(window, 'I', 'L');
                self.previous_sequence = app.frame_sequence;
                self.stage_tick = now;
                self.stage = .fire;
            },
            .fire => if (self.key_seen and app.frame_sequence >= self.previous_sequence + 2) {
                self.release();
                try capture(app, renderer, prefix, "stick-fire");
                try self.pressTouch(app, window);
                self.previous_sequence = app.frame_sequence;
                self.stage_tick = now;
                self.stage = .touch;
            },
            .touch => if (self.key_seen and app.frame_sequence >= self.previous_sequence + 8) {
                try capture(app, renderer, prefix, "touch-fire");
                self.release();
                self.stage_tick = now;
                self.previous_sequence = app.frame_sequence;
                self.stage = .sustained;
            },
            .sustained => if (app.frame_sequence >= self.previous_sequence + 2 and now - self.gameplay_tick >= app.clock_frequency * 3 and app.frame_sequence - self.gameplay_sequence >= 3) {
                const seconds = @as(f64, @floatFromInt(now - self.gameplay_tick)) / @as(f64, @floatFromInt(app.clock_frequency));
                const frames = app.frame_sequence - self.gameplay_sequence;
                std.debug.print("Input smoke gameplay sample: {d} queued frames in {d:.3} seconds, {d:.3} FPS\n", .{ frames, seconds, @as(f64, @floatFromInt(frames)) / seconds });
                self.stage = .done;
            },
            .done => {},
        }
    }
};

pub fn run(init: std.process.Init, options: Options) !void {
    const allocator = init.gpa;
    const window = try Window.init(allocator);
    defer window.deinit();
    var renderer = try Renderer.init(allocator, @intFromPtr(window.instance), @intFromPtr(window.handle), window.width, window.height);
    defer renderer.deinit();
    var canvas = Canvas.init(allocator);
    defer canvas.deinit();
    var frequency: c.LARGE_INTEGER = undefined;
    if (c.QueryPerformanceFrequency(&frequency) == 0 or frequency.QuadPart <= 0) return error.HostClock;
    var app: App = .{ .allocator = allocator, .io = init.io, .trace = options.trace, .clock_frequency = frequency.QuadPart };
    defer app.deinit();
    var input_probe: InputProbe = .{ .started = clock() };
    defer input_probe.release();
    try app.library.append(allocator, .{ .path = null, .title = try allocator.dupe(u8, "HELLO WORLD") });
    if (options.path) |path| {
        const index = try app.addFile(path);
        app.boot(index) catch |err| app.stop(err);
    } else if (options.smoke_frames != null) app.boot(0) catch |err| app.stop(err);
    while (!window.closed) {
        window.poll();
        if (window.closed) break;
        if (window.pressed[c.VK_F1]) app.boot(0) catch |err| app.stop(err);
        if (window.pressed[c.VK_F5]) app.toggle();
        const open: Rect = .{ .x = 16, .y = 152, .width = if (window.width < 900) 188 else 228, .height = 64 };
        if ((window.keys[c.VK_CONTROL] and window.pressed['O']) or (window.clicked and open.contains(window.mouse_x, window.mouse_y))) {
            window.clicked = false;
            if (try window.chooseFile()) |path| {
                defer allocator.free(path);
                const index = try app.addFile(path);
                app.boot(index) catch |err| app.stop(err);
            }
        }
        if (window.width == 0 or window.height == 0) {
            c.Sleep(16);
            continue;
        }
        if (window.resized) {
            try renderer.resize(window.width, window.height);
            try canvas.resize(window.width, window.height);
            window.resized = false;
        }
        app.advance(window) catch |err| app.stop(err);
        app.draw(&canvas, window, &renderer);
        try renderer.present(canvas.pixels, canvas.width, canvas.height);
        if (options.input_smoke) {
            try input_probe.advance(&app, window, &renderer, options.screenshot orelse "zigium-input-smoke.png");
            if (input_probe.stage == .done) break;
        }
        window.endFrame();
        if (options.smoke_frames) |count| if (renderer.frames >= count) break;
    }
    if (options.input_smoke and input_probe.stage != .done) return error.InputSmokeIncomplete;
    if (options.screenshot) |path| {
        const pixels = try renderer.readback(allocator);
        defer allocator.free(pixels);
        try drawing.writePng(init.io, allocator, path, pixels, renderer.width, renderer.height);
        std.debug.print("GPU screenshot saved: {s}\n", .{path});
    }
    if (options.smoke_frames != null) std.debug.print("GUI smoke: {d} Vulkan presents, {d} guest frames, status={s}\n", .{ renderer.frames, app.frame_sequence, @tagName(app.status) });
}
