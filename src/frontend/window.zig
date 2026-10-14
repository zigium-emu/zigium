const std = @import("std");
const c = @import("vulkan_c");

pub const Window = struct {
    allocator: std.mem.Allocator,
    instance: c.HINSTANCE,
    handle: c.HWND = null,
    width: u32 = 1200,
    height: u32 = 800,
    resized: bool = true,
    closed: bool = false,
    keys: [256]bool = @splat(false),
    pressed: [256]bool = @splat(false),
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    clicked: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);
        const instance = c.GetModuleHandleW(null) orelse return error.NoModuleHandle;
        self.* = .{ .allocator = allocator, .instance = instance };
        _ = c.SetProcessDPIAware();
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigiumDesktop");
        var window_class = std.mem.zeroes(c.WNDCLASSW);
        window_class.lpfnWndProc = procedure;
        window_class.hInstance = instance;
        window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
        window_class.lpszClassName = class_name;
        if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) return error.WindowClass;
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Zigium - Homebrew, at home");
        self.handle = c.CreateWindowExW(0, class_name, title, c.WS_OVERLAPPEDWINDOW, c.CW_USEDEFAULT, c.CW_USEDEFAULT, 1220, 840, null, null, instance, null) orelse return error.WindowCreation;
        errdefer _ = c.DestroyWindow(self.handle);
        _ = c.SetWindowLongPtrW(self.handle, c.GWLP_USERDATA, @intCast(@intFromPtr(self)));
        var rectangle: c.RECT = undefined;
        if (c.GetClientRect(self.handle, &rectangle) == 0) return error.WindowSize;
        self.width = @intCast(rectangle.right - rectangle.left);
        self.height = @intCast(rectangle.bottom - rectangle.top);
        _ = c.ShowWindow(self.handle, c.SW_SHOW);
        _ = c.SetForegroundWindow(self.handle);
        _ = c.SetFocus(self.handle);
        return self;
    }

    pub fn deinit(self: *Window) void {
        _ = c.DestroyWindow(self.handle);
        _ = c.UnregisterClassW(std.unicode.utf8ToUtf16LeStringLiteral("ZigiumDesktop"), self.instance);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn poll(self: *Window) void {
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            if (message.message == c.WM_QUIT) self.closed = true;
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
    }

    pub fn endFrame(self: *Window) void {
        @memset(&self.pressed, false);
        self.clicked = false;
    }

    pub fn chooseFile(self: *Window) !?[]u8 {
        var path: [32768]u16 = @splat(0);
        const filter = std.unicode.utf8ToUtf16LeStringLiteral("Switch homebrew (*.nro;*.nso)\x00*.nro;*.nso\x00All files\x00*.*\x00\x00");
        var options = std.mem.zeroes(c.OPENFILENAMEW);
        options.lStructSize = @sizeOf(c.OPENFILENAMEW);
        options.hwndOwner = self.handle;
        options.lpstrFilter = filter;
        options.lpstrFile = &path;
        options.nMaxFile = path.len;
        options.Flags = c.OFN_FILEMUSTEXIST | c.OFN_PATHMUSTEXIST | c.OFN_NOCHANGEDIR;
        if (c.GetOpenFileNameW(&options) == 0) {
            if (c.CommDlgExtendedError() != 0) return error.FileDialog;
            return null;
        }
        return try std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.sliceTo(&path, 0));
    }

    fn procedure(handle: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
        const address = c.GetWindowLongPtrW(handle, c.GWLP_USERDATA);
        const self: ?*Window = if (address == 0) null else @ptrFromInt(@as(usize, @bitCast(address)));
        if (self) |window| switch (message) {
            c.WM_CLOSE => {
                window.closed = true;
                return 0;
            },
            c.WM_GETMINMAXINFO => {
                const limits: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                limits.ptMinTrackSize.x = 720;
                limits.ptMinTrackSize.y = 560;
                return 0;
            },
            c.WM_SIZE => {
                const bits: usize = @bitCast(lparam);
                window.width = @as(u16, @truncate(bits));
                window.height = @as(u16, @truncate(bits >> 16));
                window.resized = true;
                return 0;
            },
            c.WM_KEYDOWN => {
                if (wparam < window.keys.len) {
                    if (!window.keys[wparam]) window.pressed[wparam] = true;
                    window.keys[wparam] = true;
                }
                return 0;
            },
            c.WM_KEYUP => {
                if (wparam < window.keys.len) window.keys[wparam] = false;
                return 0;
            },
            c.WM_KILLFOCUS => @memset(&window.keys, false),
            c.WM_MOUSEMOVE => {
                const bits: usize = @bitCast(lparam);
                window.mouse_x = @as(i16, @bitCast(@as(u16, @truncate(bits))));
                window.mouse_y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));
                return 0;
            },
            c.WM_LBUTTONUP => {
                window.clicked = true;
                return 0;
            },
            c.WM_ERASEBKGND => return 1,
            c.WM_PAINT => {
                _ = c.ValidateRect(handle, null);
                return 0;
            },
            else => {},
        };
        return c.DefWindowProcW(handle, message, wparam, lparam);
    }
};
