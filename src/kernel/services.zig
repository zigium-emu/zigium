const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;
const legacy_hid = @import("../input/hid.zig");
pub const ipc = @import("ipc.zig");

pub const Result = struct {
    pub const invalid_handle: u32 = 0xe401;
    pub const invalid_size: u32 = 0xca01;
    pub const invalid_address: u32 = 0xce01;
    pub const not_implemented: u32 = 0xf601;
    pub const service_not_found: u32 = 0x415;
    pub const am_no_message: u32 = 0x680;
    pub const path_not_found: u32 = 0x202;
};

pub const SessionKind = enum {
    sm,
    apm,
    apm_session,
    applet,
    applet_proxy,
    common_state,
    self_controller,
    window_controller,
    audio_controller,
    display_controller,
    application_functions,
    library_applet_creator,
    debug_functions,
    hid,
    hid_resource,
    time,
    system_clock,
    steady_clock,
    timezone,
    fsp,
    filesystem,
    set,
    setsys,
    nvdrv,
    vi,
    vi_display,
    vi_system,
    vi_manager,
    binder,
};
pub const Frame = struct {
    cpu_address: u64,
    byte_length: usize,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    block_height_log2: u4,
    flip_v: bool,
    flip_h: bool,
    sequence: u64,
};
const BufferState = enum { free, dequeued };
const GraphicBuffer = struct { bytes: [364]u8, state: BufferState = .free };
const NvMap = struct { handle: u32, size: usize, address: u64 = 0, kind: u8 = 0, allocated: bool = false };
const NvDevice = enum { control_gpu, address_space, nvmap, channel, control };
const NvFile = struct { id: u32, device: NvDevice, priority: u32 = 0x64, class: u32 = 0, nvmap_fd: u32 = 0, userdata: u64 = 0 };
const GpuMapping = struct { address: u64, size: usize, cpu_address: u64, backing_size: usize, kind: u32 };
pub const Event = struct { signaled: bool };
pub const Mapping = struct { address: u64, size: usize };
pub const Shared = struct {
    bytes: []u8,
    mappings: [8]Mapping = undefined,
    mapping_count: usize = 0,
};
pub const Transfer = struct { address: u64, size: usize, permissions: u32 };
pub const Domain = struct {
    objects: [64]?SessionKind = @splat(null),
    count: u32 = 1,
};
pub const Session = struct { kind: SessionKind, domain: ?*Domain = null };
pub const Object = union(enum) { session: Session, event: *Event, shared: *Shared, transfer: Transfer };

pub const Services = struct {
    allocator: std.mem.Allocator,
    handles: [256]?Object = @splat(null),
    handle_ids: [256]u32 = @splat(0),
    next_handle: u32 = 0x200,
    events: std.ArrayList(*Event) = .empty,
    shared: std.ArrayList(*Shared) = .empty,
    domains: std.ArrayList(*Domain) = .empty,
    last_session: SessionKind = .sm,
    last_command: u32 = 0,
    last_result: u32 = 0,
    last_failure_session: SessionKind = .sm,
    last_failure_command: u32 = 0,
    last_failure_result: u32 = 0,
    request_count: u64 = 0,
    trace: bool = false,
    registered: bool = false,
    performance_config: [2]u32 = .{ 0x00010000, 0x00010000 },
    operation_mode: u8 = 0,
    performance_mode: u32 = 0,
    focus_mode: [3]u8 = .{ 0, 0, 0 },
    suspend_out_of_focus: bool = false,
    operation_notifications: bool = false,
    performance_notifications: bool = false,
    screenshot_permission: u32 = 0,
    foreground: bool = false,
    focus_message_pending: bool = true,
    common_event: ?*Event = null,
    exit_requested: bool = false,
    hid_style: u32 = 0,
    hid_assignment: [8]u8 = @splat(2),
    input_sample: u64 = 0,
    hid_active: bool = false,
    hid_shared: ?*Shared = null,
    unix_time: i64 = 1_791_964_800,
    elapsed_ns: u64 = 0,
    display_open: bool = false,
    layer_open: bool = false,
    layer_scaling: u32 = 0,
    vsync_event: ?*Event = null,
    binder_weak_refs: i32 = 0,
    binder_strong_refs: i32 = 0,
    binder_connected: bool = false,
    binder_buffers: [8]?GraphicBuffer = @splat(null),
    binder_next_slot: usize = 0,
    last_binder_transaction: u32 = 0,
    nvmap: [64]?NvMap = @splat(null),
    nv_files: [16]?NvFile = @splat(null),
    next_nv_fd: u32 = 1,
    next_nvmap_handle: u32 = 1,
    nv_initialized: bool = false,
    nv_client_pid: u64 = 0,
    gpu_mappings: [128]?GpuMapping = @splat(null),
    next_gpu_address: u64 = 0x100000000,
    last_ioctl: u32 = 0,
    last_nv_error: u32 = 0,
    frame_sequence: u64 = 0,
    latest_frame: ?Frame = null,

    pub fn init(allocator: std.mem.Allocator) Services {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Services) void {
        for (self.events.items) |event| self.allocator.destroy(event);
        self.events.deinit(self.allocator);
        for (self.shared.items) |shared| {
            self.allocator.free(shared.bytes);
            self.allocator.destroy(shared);
        }
        self.shared.deinit(self.allocator);
        for (self.domains.items) |domain| self.allocator.destroy(domain);
        self.domains.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn allocate(self: *Services, object: Object) !u32 {
        for (self.handles, 0..) |slot, i| {
            if (slot == null) {
                const handle = self.next_handle;
                if (handle >= 0x80000000) return error.HandleLimit;
                self.next_handle += 1;
                self.handles[i] = object;
                self.handle_ids[i] = handle;
                return handle;
            }
        }
        return error.HandleLimit;
    }

    pub fn get(self: *Services, handle: u32) !*Object {
        for (&self.handles, self.handle_ids) |*slot, id| {
            if (id == handle and slot.* != null) return &slot.*.?;
        }
        return error.InvalidHandle;
    }

    pub fn close(self: *Services, handle: u32) !void {
        for (&self.handles, &self.handle_ids) |*slot, *id| {
            if (id.* == handle and slot.* != null) {
                slot.* = null;
                id.* = 0;
                return;
            }
        }
        return error.InvalidHandle;
    }

    pub fn connect(self: *Services, name: []const u8) !u32 {
        if (!std.mem.eql(u8, name, "sm:")) return error.ServiceNotFound;
        return self.allocate(.{ .session = .{ .kind = .sm } });
    }

    pub fn createEvent(self: *Services, signaled: bool) !u32 {
        if (self.events.items.len >= 256) return error.HandleLimit;
        const event = try self.allocator.create(Event);
        errdefer self.allocator.destroy(event);
        event.* = .{ .signaled = signaled };
        try self.events.append(self.allocator, event);
        return self.allocate(.{ .event = event });
    }

    pub fn isSignaled(self: *Services, handle: u32) !bool {
        return switch ((try self.get(handle)).*) {
            .event => |event| event.signaled,
            else => error.InvalidHandle,
        };
    }

    pub fn resetEvent(self: *Services, handle: u32) !void {
        switch ((try self.get(handle)).*) {
            .event => |event| event.signaled = false,
            else => return error.InvalidHandle,
        }
    }

    pub fn signalEvent(self: *Services, handle: u32) !void {
        switch ((try self.get(handle)).*) {
            .event => |event| event.signaled = true,
            else => return error.InvalidHandle,
        }
    }

    pub fn createTransfer(self: *Services, address: u64, size: usize, permissions: u32) !u32 {
        if (address & 0xfff != 0 or size == 0 or size & 0xfff != 0 or size > 64 * 1024 * 1024) return error.InvalidMapping;
        if (permissions != 0 and permissions != 1 and permissions != 3) return error.InvalidPermissions;
        return self.allocate(.{ .transfer = .{ .address = address, .size = size, .permissions = permissions } });
    }

    fn newShared(self: *Services, size: usize) !*Shared {
        if (self.shared.items.len >= 16) return error.HandleLimit;
        const resource = try self.allocator.create(Shared);
        errdefer self.allocator.destroy(resource);
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);
        resource.* = .{ .bytes = bytes };
        try self.shared.append(self.allocator, resource);
        return resource;
    }

    pub fn mapShared(self: *Services, memory: *Memory, handle: u32, address: u64, size: usize, permissions: u32) !void {
        const object = try self.get(handle);
        const shared = switch (object.*) {
            .shared => |value| value,
            else => return error.InvalidHandle,
        };
        if (size != shared.bytes.len or shared.mapping_count == shared.mappings.len) return error.InvalidMapping;
        if (permissions != 1 and permissions != 3) return error.InvalidPermissions;
        try memory.mapWithState(address, size, .{ .read = true, .write = true }, 6);
        errdefer memory.unmap(address, size) catch {};
        try memory.write(address, shared.bytes);
        try memory.protect(address, size, .{ .read = true, .write = permissions == 3 });
        shared.mappings[shared.mapping_count] = .{ .address = address, .size = size };
        shared.mapping_count += 1;
    }

    pub fn syncShared(self: *Services, memory: *Memory) !void {
        for (self.shared.items) |shared| {
            for (shared.mappings[0..shared.mapping_count]) |mapping| {
                const info = try memory.query(mapping.address);
                if (info.base != mapping.address or info.size != mapping.size or info.state != 6) continue;
                try memory.protect(mapping.address, mapping.size, .{ .read = true, .write = true });
                defer memory.protect(mapping.address, mapping.size, info.permissions) catch {};
                try memory.write(mapping.address, shared.bytes);
            }
        }
    }

    pub fn unmapShared(self: *Services, memory: *Memory, handle: u32, address: u64, size: usize) !void {
        const shared = switch ((try self.get(handle)).*) {
            .shared => |value| value,
            else => return error.InvalidHandle,
        };
        for (shared.mappings[0..shared.mapping_count], 0..) |mapping, i| {
            if (mapping.address == address and mapping.size == size) {
                try memory.unmap(address, size);
                shared.mapping_count -= 1;
                shared.mappings[i] = shared.mappings[shared.mapping_count];
                return;
            }
        }
        return error.InvalidMapping;
    }

    pub fn signalVsync(self: *Services) void {
        if (self.vsync_event) |event| event.signaled = true;
    }

    pub fn updateInput(self: *Services, memory: *Memory, buttons: u64, left_x: i32, left_y: i32) !void {
        const shared = self.hid_shared orelse return;
        self.input_sample +%= 1;
        try legacy_hid.writeSample(shared.bytes, self.input_sample, self.elapsed_ns, .{ .buttons = buttons, .left_x = left_x, .left_y = left_y });
        try self.syncShared(memory);
    }

    fn kindForName(name: []const u8) ?SessionKind {
        const names = [_]struct { name: []const u8, kind: SessionKind }{
            .{ .name = "apm", .kind = .apm },     .{ .name = "appletOE", .kind = .applet }, .{ .name = "appletAE", .kind = .applet },
            .{ .name = "hid", .kind = .hid },     .{ .name = "time:u", .kind = .time },     .{ .name = "time:s", .kind = .time },
            .{ .name = "fsp-srv", .kind = .fsp }, .{ .name = "set", .kind = .set },         .{ .name = "set:sys", .kind = .setsys },
            .{ .name = "nvdrv", .kind = .nvdrv }, .{ .name = "nvdrv:a", .kind = .nvdrv },   .{ .name = "nvdrv:s", .kind = .nvdrv },
            .{ .name = "vi:u", .kind = .vi },     .{ .name = "vi:s", .kind = .vi },         .{ .name = "vi:m", .kind = .vi },
        };
        for (names) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.kind;
        return null;
    }

    fn child(self: *Services, session: *Session, response: *ipc.Response, kind: SessionKind) !void {
        if (session.domain) |domain| {
            if (domain.count >= domain.objects.len) return error.HandleLimit;
            const id = domain.count + 1;
            domain.objects[domain.count] = kind;
            domain.count += 1;
            response.domain_object = id;
        } else response.move_handle = try self.allocate(.{ .session = .{ .kind = kind } });
    }

    fn nativeWindow(memory: *Memory, request: *const ipc.Request) !u64 {
        const buffer = request.outputBuffer() orelse return error.InvalidIpc;
        if (buffer.size < 0x28) return error.InvalidIpc;
        var bytes: [0x28]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], 0x18, .little);
        std.mem.writeInt(u32, bytes[4..8], 0x10, .little);
        std.mem.writeInt(u32, bytes[12..16], 0x28, .little);
        std.mem.writeInt(u32, bytes[16..20], 2, .little);
        std.mem.writeInt(u32, bytes[24..28], 1, .little);
        @memcpy(bytes[28..35], "dispdrv");
        try memory.write(buffer.address, &bytes);
        return bytes.len;
    }

    fn mapByHandle(self: *Services, handle: u32) !*NvMap {
        for (&self.nvmap) |*entry| if (entry.*) |*mapping| {
            if (mapping.handle == handle) return mapping;
        };
        return error.InvalidIpc;
    }

    fn dimensions(parcel: *ipc.Parcel) !void {
        try parcel.put(u32, 1280);
        try parcel.put(u32, 720);
        try parcel.put(u32, 0);
        try parcel.put(u32, 0);
    }

    fn nvFile(self: *Services, fd: u32) !*NvFile {
        for (&self.nv_files) |*entry| if (entry.*) |*file| {
            if (file.id == fd) return file;
        };
        return error.InvalidIpc;
    }

    fn gpuAddress(self: *Services, size: usize, alignment: u64) !u64 {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidIpc;
        const address = std.mem.alignForward(u64, self.next_gpu_address, alignment);
        const end = std.math.add(u64, address, size) catch return error.InvalidIpc;
        if (end >= 1 << 40) return error.InvalidIpc;
        self.next_gpu_address = end;
        return address;
    }

    fn ioctl(self: *Services, memory: *Memory, fd: u32, number: u32, bytes: []u8) !u32 {
        const file = try self.nvFile(fd);
        self.last_ioctl = number;
        const code = number & 0xffff;
        switch (file.device) {
            .nvmap => switch (code) {
                0x0101 => {
                    if (bytes.len != 8) return 4;
                    const size = std.mem.readInt(u32, bytes[0..4], .little);
                    if (size == 0 or size > 64 * 1024 * 1024) return 4;
                    for (&self.nvmap) |*entry| if (entry.* == null) {
                        const handle = self.next_nvmap_handle;
                        self.next_nvmap_handle += 1;
                        entry.* = .{ .handle = handle, .size = size };
                        std.mem.writeInt(u32, bytes[4..8], handle, .little);
                        return 0;
                    };
                    return 6;
                },
                0x0103 => {
                    if (bytes.len != 8) return 4;
                    const handle = std.mem.readInt(u32, bytes[0..4], .little);
                    _ = try self.mapByHandle(handle);
                    std.mem.writeInt(u32, bytes[4..8], handle, .little);
                    return 0;
                },
                0x0104 => {
                    if (bytes.len != 32) return 4;
                    const mapping = try self.mapByHandle(std.mem.readInt(u32, bytes[0..4], .little));
                    const alignment = std.mem.readInt(u32, bytes[12..16], .little);
                    const address = std.mem.readInt(u64, bytes[24..32], .little);
                    if (alignment == 0 or !std.math.isPowerOfTwo(alignment) or address & 0xfff != 0) return 4;
                    try ipc.validateRange(memory, address, mapping.size, true);
                    mapping.address = address;
                    mapping.kind = bytes[16];
                    mapping.allocated = true;
                    return 0;
                },
                0x010e => {
                    if (bytes.len != 8) return 4;
                    const handle = std.mem.readInt(u32, bytes[4..8], .little);
                    _ = try self.mapByHandle(handle);
                    std.mem.writeInt(u32, bytes[0..4], handle, .little);
                    return 0;
                },
                0x0105 => {
                    if (bytes.len != 24) return 4;
                    const handle = std.mem.readInt(u32, bytes[0..4], .little);
                    const mapping = try self.mapByHandle(handle);
                    std.mem.writeInt(u64, bytes[8..16], mapping.address, .little);
                    std.mem.writeInt(u32, bytes[16..20], @intCast(mapping.size), .little);
                    std.mem.writeInt(u32, bytes[20..24], 0, .little);
                    mapping.allocated = false;
                    return 0;
                },
                else => return 1,
            },
            .control_gpu => switch (code) {
                0x4701 => {
                    if (bytes.len != 4) return 4;
                    std.mem.writeInt(u32, bytes[0..4], 0x1000, .little);
                    return 0;
                },
                0x4702 => {
                    if (bytes.len != 40) return 4;
                    const values = [_]u32{ 32, 32, 32, 0x800, 0x100, 0x20, 0xc0, 2, 1, 1 };
                    for (values, 0..) |value, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], value, .little);
                    return 0;
                },
                0x4705 => {
                    if (bytes.len != 176) return 4;
                    std.mem.writeInt(u64, bytes[0..8], 0xa0, .little);
                    @memset(bytes[16..], 0);
                    const values = [_]u32{ 0x120, 0xb, 0xa1, 1, 0x40000, 0, 0, 0, 2, 0x20, 0x20000, 0x20000, 0x1b, 0x30000, 1, 0x503, 0x503, 0x80, 0x28, 0, 0x55, 0, 0x902d, 0xb197, 0xb1c0, 0xb06f, 0xa140, 0xb0b5, 1, 0, 2, 1, 0, 1, 0x21d70, 0, 0x30326d67, 0x62, 0, 0 };
                    for (values, 0..) |value, i| std.mem.writeInt(u32, bytes[16 + i * 4 ..][0..4], value, .little);
                    return 0;
                },
                0x4706 => {
                    if (bytes.len != 24) return 4;
                    std.mem.writeInt(u32, bytes[12..16], 3, .little);
                    return 0;
                },
                0x4714 => {
                    if (bytes.len != 8) return 4;
                    std.mem.writeInt(u32, bytes[0..4], 7, .little);
                    std.mem.writeInt(u32, bytes[4..8], 0, .little);
                    return 0;
                },
                else => return 1,
            },
            .address_space => switch (code) {
                0x4109 => {
                    if (bytes.len != 40) return 4;
                    return 0;
                },
                0x4101 => {
                    if (bytes.len != 4 or (try self.nvFile(std.mem.readInt(u32, bytes[0..4], .little))).device != .channel) return 4;
                    return 0;
                },
                0x4102 => {
                    if (bytes.len != 24) return 4;
                    const pages = std.mem.readInt(u32, bytes[0..4], .little);
                    const page_size = std.mem.readInt(u32, bytes[4..8], .little);
                    const flags = std.mem.readInt(u32, bytes[8..12], .little);
                    if (flags != 0 or pages == 0 or (page_size != 0x1000 and page_size != 0x10000 and page_size != 0x20000)) return 4;
                    const size = std.math.mul(usize, pages, page_size) catch return 4;
                    const address = try self.gpuAddress(size, std.mem.readInt(u64, bytes[16..24], .little));
                    std.mem.writeInt(u64, bytes[16..24], address, .little);
                    return 0;
                },
                0x4106 => {
                    if (bytes.len != 40) return 4;
                    const flags = std.mem.readInt(u32, bytes[0..4], .little);
                    const kind = std.mem.readInt(u32, bytes[4..8], .little);
                    if (flags & 0x100 != 0) {
                        const offset = std.mem.readInt(u64, bytes[16..24], .little);
                        const size = std.mem.readInt(u64, bytes[24..32], .little);
                        const address = std.mem.readInt(u64, bytes[32..40], .little);
                        for (&self.gpu_mappings) |*entry| if (entry.*) |*mapping| {
                            if (mapping.address == address and offset <= mapping.size and size <= mapping.size - offset) {
                                mapping.kind = kind;
                                return 0;
                            }
                        };
                        return 4;
                    }
                    const mapping = try self.mapByHandle(std.mem.readInt(u32, bytes[8..12], .little));
                    if (!mapping.allocated) return 4;
                    const offset = std.mem.readInt(u64, bytes[16..24], .little);
                    var size = std.mem.readInt(u64, bytes[24..32], .little);
                    if (size == 0) size = mapping.size;
                    const requested_page = std.mem.readInt(u32, bytes[12..16], .little);
                    const page_size: usize = if (requested_page == 0) 0x10000 else requested_page;
                    if (page_size != 0x1000 and page_size != 0x10000 and page_size != 0x20000) return 4;
                    const virtual_size = std.mem.alignForward(usize, mapping.size, page_size);
                    if (offset > mapping.size or size > virtual_size - offset) return 4;
                    var address = std.mem.readInt(u64, bytes[32..40], .little);
                    if (flags & (1 | 0x100) == 0) address = try self.gpuAddress(@intCast(size), 0x10000);
                    const end = std.math.add(u64, address, size) catch return 4;
                    if (address == 0 or end >= 1 << 40) return 4;
                    for (&self.gpu_mappings) |*entry| if (entry.* == null) {
                        entry.* = .{ .address = address, .size = @intCast(size), .cpu_address = mapping.address + offset, .backing_size = @min(@as(usize, @intCast(size)), mapping.size - @as(usize, @intCast(offset))), .kind = kind };
                        std.mem.writeInt(u32, bytes[12..16], 0x10000, .little);
                        std.mem.writeInt(u64, bytes[32..40], address, .little);
                        return 0;
                    };
                    return 6;
                },
                0x4108 => {
                    if (bytes.len != 64) return 4;
                    std.mem.writeInt(u32, bytes[8..12], 48, .little);
                    std.mem.writeInt(u64, bytes[16..24], 0x100000, .little);
                    std.mem.writeInt(u32, bytes[24..28], 0x1000, .little);
                    std.mem.writeInt(u64, bytes[32..40], 0xff00, .little);
                    std.mem.writeInt(u64, bytes[40..48], 0x100000000, .little);
                    std.mem.writeInt(u32, bytes[48..52], 0x10000, .little);
                    std.mem.writeInt(u64, bytes[56..64], 0xff0000, .little);
                    return 0;
                },
                else => return 1,
            },
            .channel => switch (code) {
                0x4801 => {
                    if (bytes.len != 4) return 4;
                    const other_fd = std.mem.readInt(u32, bytes[0..4], .little);
                    if ((try self.nvFile(other_fd)).device != .nvmap) return 4;
                    file.nvmap_fd = other_fd;
                    return 0;
                },
                0x4809 => {
                    if (bytes.len != 16) return 4;
                    file.class = std.mem.readInt(u32, bytes[0..4], .little);
                    std.mem.writeInt(u64, bytes[8..16], 1, .little);
                    return 0;
                },
                0x480b => {
                    if (bytes.len != 16) return 4;
                    return 0;
                },
                0x480c => {
                    if (bytes.len != 24) return 4;
                    _ = try self.mapByHandle(std.mem.readInt(u32, bytes[16..20], .little));
                    return 0;
                },
                0x480d => {
                    if (bytes.len != 4) return 4;
                    const priority = std.mem.readInt(u32, bytes[0..4], .little);
                    if (priority != 0x32 and priority != 0x64 and priority != 0x96) return 4;
                    file.priority = priority;
                    return 0;
                },
                0x4714, 0x4814 => {
                    if (bytes.len != 8) return 4;
                    file.userdata = std.mem.readInt(u64, bytes[0..8], .little);
                    try ipc.validateRange(memory, file.userdata, 0x1000, true);
                    return 0;
                },
                0x481a => {
                    if (bytes.len != 32) return 4;
                    std.mem.writeInt(u32, bytes[12..16], 1, .little);
                    std.mem.writeInt(u32, bytes[16..20], 0, .little);
                    return 0;
                },
                else => return 1,
            },
            .control => return 1,
        }
    }

    fn nvidia(self: *Services, memory: *Memory, request: *const ipc.Request, response: *ipc.Response) !void {
        switch (request.command_id) {
            0 => {
                if (!self.nv_initialized) return;
                const buffer = request.inputBuffer() orelse return error.InvalidIpc;
                if (buffer.size == 0 or buffer.size > 128) return error.InvalidIpc;
                var bytes: [128]u8 = undefined;
                try memory.read(buffer.address, bytes[0..buffer.size]);
                const length = std.mem.indexOfScalar(u8, bytes[0..buffer.size], 0) orelse buffer.size;
                const name = bytes[0..length];
                const device: NvDevice = if (std.mem.eql(u8, name, "/dev/nvhost-ctrl-gpu")) .control_gpu else if (std.mem.eql(u8, name, "/dev/nvhost-as-gpu")) .address_space else if (std.mem.eql(u8, name, "/dev/nvmap")) .nvmap else if (std.mem.eql(u8, name, "/dev/nvhost-gpu")) .channel else if (std.mem.eql(u8, name, "/dev/nvhost-ctrl")) .control else return;
                for (&self.nv_files) |*entry| if (entry.* == null) {
                    const fd = self.next_nv_fd;
                    self.next_nv_fd += 1;
                    entry.* = .{ .id = fd, .device = device };
                    response.integer(u32, fd);
                    response.integer(u32, 0);
                    response.result = 0;
                    return;
                };
            },
            1 => {
                if (!self.nv_initialized) return;
                const fd = try request.integer(u32, 0);
                const number = try request.integer(u32, 4);
                const size = (number >> 16) & 0x3fff;
                const direction = number >> 30;
                if (size == 0 or size > 1024) return;
                var bytes: [1024]u8 = @splat(0);
                const output_buffer = if (direction & 2 != 0) request.outputBuffer() orelse return error.InvalidIpc else null;
                if (output_buffer) |buffer| if (buffer.size < size) return error.InvalidIpc;
                if (direction & 1 != 0) {
                    const buffer = request.inputBuffer() orelse return error.InvalidIpc;
                    if (buffer.size < size) return error.InvalidIpc;
                    try memory.read(buffer.address, bytes[0..size]);
                }
                const result = self.ioctl(memory, fd, number, bytes[0..size]) catch |err| switch (err) {
                    error.InvalidIpc => @as(u32, 4),
                    else => return err,
                };
                self.last_nv_error = result;
                if (result == 0 and direction & 2 != 0) {
                    const buffer = output_buffer.?;
                    try memory.write(buffer.address, bytes[0..size]);
                }
                response.integer(u32, result);
                response.result = 0;
                if (self.trace) std.debug.print("NV ioctl=0x{x} fd={d} status={d}\n", .{ number, fd, result });
            },
            2 => {
                const fd = try request.integer(u32, 0);
                for (&self.nv_files) |*entry| if (entry.*) |file| {
                    if (file.id == fd) {
                        entry.* = null;
                        response.integer(u32, 0);
                        response.result = 0;
                        return;
                    }
                };
            },
            3 => {
                if (request.copy_count != 2) return;
                const transfer = switch ((try self.get(request.copy_handles[1])).*) {
                    .transfer => |value| value,
                    else => return,
                };
                if (request.copy_handles[0] != 0xffff8001 or try request.integer(u32, 0) != transfer.size) return;
                try ipc.validateRange(memory, transfer.address, transfer.size, true);
                self.nv_initialized = true;
                response.result = 0;
            },
            4 => {
                _ = try self.nvFile(try request.integer(u32, 0));
                response.copy_handle = try self.createEvent(false);
                response.integer(u32, 0);
                response.result = 0;
            },
            8 => {
                self.nv_client_pid = try request.integer(u64, 0);
                response.result = 0;
            },
            else => {},
        }
    }

    fn transact(self: *Services, memory: *Memory, request: *const ipc.Request, response: *ipc.Response) !void {
        if (try request.integer(u32, 0) != 1) return;
        const transaction = try request.integer(u32, 4);
        self.last_binder_transaction = transaction;
        var input = try ipc.Parcel.read(memory, request.inputBuffer() orelse return error.InvalidIpc);
        try input.interface("android.gui.IGraphicBufferProducer");
        var output: ipc.Parcel = .{};
        switch (transaction) {
            1 => {
                const slot = try input.take(u32);
                if (slot >= self.binder_buffers.len or self.binder_buffers[slot] == null) return;
                try output.put(u32, 1);
                try output.putObject(&self.binder_buffers[slot].?.bytes);
                try output.put(i32, 0);
            },
            3 => {
                if (!self.binder_connected) return;
                _ = try input.take(u32);
                const width = try input.take(u32);
                const height = try input.take(u32);
                const format = try input.take(u32);
                _ = try input.take(u32);
                var found: ?usize = null;
                for (0..self.binder_buffers.len) |i| {
                    const slot = (self.binder_next_slot + i) % self.binder_buffers.len;
                    if (self.binder_buffers[slot]) |buffer| {
                        const w = std.mem.readInt(u32, buffer.bytes[4..8], .little);
                        const h = std.mem.readInt(u32, buffer.bytes[8..12], .little);
                        const f = std.mem.readInt(u32, buffer.bytes[16..20], .little);
                        if (buffer.state == .free and (width == 0 or width == w) and (height == 0 or height == h) and (format == 0 or format == f)) {
                            found = slot;
                            break;
                        }
                    }
                }
                if (found) |slot| {
                    self.binder_buffers[slot].?.state = .dequeued;
                    self.binder_next_slot = (slot + 1) % self.binder_buffers.len;
                    try output.put(u32, @intCast(slot));
                    try output.put(u32, 0);
                    try output.put(i32, 0);
                } else {
                    try output.put(i32, -1);
                    try output.put(u32, 0);
                    try output.put(i32, -11);
                }
            },
            7 => {
                if (!self.binder_connected) return;
                const slot = try input.take(u32);
                const parameters = try input.object();
                if (slot >= self.binder_buffers.len or self.binder_buffers[slot] == null or parameters.len < 84) return;
                const buffer = &self.binder_buffers[slot].?;
                if (buffer.state != .dequeued) return;
                const mapping = try self.mapByHandle(std.mem.readInt(u32, buffer.bytes[44..48], .little));
                if (!mapping.allocated) return;
                const offset = std.mem.readInt(u32, buffer.bytes[120..124], .little);
                const length = std.mem.readInt(u32, buffer.bytes[80..84], .little);
                const width = std.mem.readInt(u32, buffer.bytes[4..8], .little);
                const height = std.mem.readInt(u32, buffer.bytes[8..12], .little);
                const transform = std.mem.readInt(u32, parameters[32..36], .little);
                if (offset > mapping.size or length > mapping.size - offset or width == 0 or height == 0 or width > 4096 or height > 4096 or transform & ~@as(u32, 3) != 0) return;
                try ipc.validateRange(memory, mapping.address + offset, length, false);
                self.frame_sequence += 1;
                self.latest_frame = .{
                    .cpu_address = mapping.address + offset,
                    .byte_length = length,
                    .width = width,
                    .height = height,
                    .stride = std.mem.readInt(u32, buffer.bytes[12..16], .little),
                    .format = std.mem.readInt(u32, buffer.bytes[16..20], .little),
                    .block_height_log2 = @truncate(std.mem.readInt(u32, buffer.bytes[128..132], .little)),
                    .flip_v = transform & 2 != 0,
                    .flip_h = transform & 1 != 0,
                    .sequence = self.frame_sequence,
                };
                buffer.state = .free;
                try dimensions(&output);
                try output.put(i32, 0);
            },
            8 => {
                const slot = try input.take(u32);
                _ = try input.object();
                if (slot >= self.binder_buffers.len or self.binder_buffers[slot] == null or self.binder_buffers[slot].?.state != .dequeued) return;
                self.binder_buffers[slot].?.state = .free;
                try output.put(i32, 0);
            },
            9 => {
                const attribute = try input.take(u32);
                const value: u32 = switch (attribute) {
                    0, 6 => 1280,
                    1, 7 => 720,
                    2 => 1,
                    3 => 0,
                    else => return,
                };
                try output.put(u32, value);
                try output.put(i32, 0);
            },
            10 => {
                if (self.binder_connected or try input.take(u32) != 0) return;
                if (try input.take(u32) != 2) return;
                _ = try input.take(u32);
                self.binder_connected = true;
                try dimensions(&output);
                try output.put(i32, 0);
            },
            11 => {
                if (try input.take(u32) != 2) return;
                self.binder_connected = false;
                try output.put(i32, 0);
            },
            14 => {
                const slot = try input.take(u32);
                const has_buffer = try input.take(u32);
                if (slot >= self.binder_buffers.len) return;
                if (has_buffer == 0) self.binder_buffers[slot] = null else {
                    const bytes = try input.object();
                    if (bytes.len != 364 or std.mem.readInt(u32, bytes[0..4], .little) != 0x47424652 or std.mem.readInt(u32, bytes[32..36], .little) != 0) return;
                    const width = std.mem.readInt(u32, bytes[4..8], .little);
                    const height = std.mem.readInt(u32, bytes[8..12], .little);
                    const stride = std.mem.readInt(u32, bytes[12..16], .little);
                    const format = std.mem.readInt(u32, bytes[16..20], .little);
                    const block_height = std.mem.readInt(u32, bytes[128..132], .little);
                    if (width == 0 or height == 0 or width > 4096 or height > 4096 or stride < width or stride > 4096 or format != 1 or block_height > 5) return;
                    if (std.mem.readInt(u32, bytes[112..116], .little) != stride * 4) return;
                    const mapping = try self.mapByHandle(std.mem.readInt(u32, bytes[44..48], .little));
                    if (!mapping.allocated) return;
                    var buffer: GraphicBuffer = .{ .bytes = undefined };
                    @memcpy(&buffer.bytes, bytes);
                    self.binder_buffers[slot] = buffer;
                }
                try output.put(i32, 0);
            },
            else => return,
        }
        try output.write(memory, request.outputBuffer() orelse return error.InvalidIpc);
        response.result = 0;
    }

    fn command(self: *Services, memory: *Memory, session: *Session, kind: SessionKind, request: *const ipc.Request, response: *ipc.Response) !void {
        response.result = Result.not_implemented;
        switch (kind) {
            .sm => switch (request.command_id) {
                0 => {
                    if (!request.send_pid) return;
                    self.registered = true;
                    response.result = 0;
                },
                1 => {
                    if (!self.registered) {
                        response.result = Result.service_not_found;
                        return;
                    }
                    const encoded = try request.integer(u64, 0);
                    var name: [8]u8 = undefined;
                    std.mem.writeInt(u64, &name, encoded, .little);
                    const length = std.mem.indexOfScalar(u8, &name, 0) orelse name.len;
                    if (kindForName(name[0..length])) |child_kind| {
                        response.move_handle = try self.allocate(.{ .session = .{ .kind = child_kind } });
                        response.result = 0;
                    } else response.result = Result.service_not_found;
                },
                else => {},
            },
            .apm => switch (request.command_id) {
                0 => {
                    try self.child(session, response, .apm_session);
                    response.result = 0;
                },
                1 => {
                    response.integer(u32, self.performance_mode);
                    response.result = 0;
                },
                else => {},
            },
            .apm_session => switch (request.command_id) {
                0, 1 => {
                    const mode = try request.integer(u32, 0);
                    if (mode >= self.performance_config.len) {
                        response.result = 0xf001;
                        return;
                    }
                    if (request.command_id == 0) self.performance_config[mode] = try request.integer(u32, 4) else response.integer(u32, self.performance_config[mode]);
                    response.result = 0;
                },
                else => {},
            },
            .applet => switch (request.command_id) {
                0, 100, 200, 201, 300 => {
                    try self.child(session, response, .applet_proxy);
                    response.result = 0;
                },
                else => {},
            },
            .applet_proxy => {
                const child_kind: ?SessionKind = switch (request.command_id) {
                    0 => .common_state,
                    1 => .self_controller,
                    2 => .window_controller,
                    3 => .audio_controller,
                    4 => .display_controller,
                    11 => .library_applet_creator,
                    20 => .application_functions,
                    1000 => .debug_functions,
                    else => null,
                };
                if (child_kind) |value| {
                    try self.child(session, response, value);
                    response.result = 0;
                }
            },
            .common_state => switch (request.command_id) {
                0 => {
                    if (self.common_event) |event| {
                        response.copy_handle = try self.allocate(.{ .event = event });
                    } else {
                        const handle = try self.createEvent(self.focus_message_pending);
                        self.common_event = (try self.get(handle)).event;
                        response.copy_handle = handle;
                    }
                    response.result = 0;
                },
                1 => {
                    if (self.focus_message_pending) {
                        self.focus_message_pending = false;
                        if (self.common_event) |event| event.signaled = false;
                        response.integer(u32, 0xf);
                        response.result = 0;
                    } else response.result = Result.am_no_message;
                },
                5 => {
                    response.integer(u8, self.operation_mode);
                    response.result = 0;
                },
                6 => {
                    response.integer(u32, self.performance_mode);
                    response.result = 0;
                },
                9 => {
                    response.integer(u8, 1);
                    response.result = 0;
                },
                else => {},
            },
            .self_controller => switch (request.command_id) {
                0 => {
                    self.exit_requested = true;
                    response.result = 0;
                },
                10 => {
                    self.screenshot_permission = try request.integer(u32, 0);
                    response.result = 0;
                },
                11 => {
                    self.operation_notifications = try request.integer(u8, 0) != 0;
                    response.result = 0;
                },
                12 => {
                    self.performance_notifications = try request.integer(u8, 0) != 0;
                    response.result = 0;
                },
                13 => {
                    for (&self.focus_mode, 0..) |*value, i| value.* = try request.integer(u8, i);
                    response.result = 0;
                },
                16 => {
                    self.suspend_out_of_focus = try request.integer(u8, 0) != 0;
                    response.result = 0;
                },
                40 => {
                    self.layer_open = true;
                    response.integer(u64, 1);
                    response.result = 0;
                },
                else => {},
            },
            .window_controller => switch (request.command_id) {
                1 => {
                    response.integer(u64, 1);
                    response.result = 0;
                },
                10 => {
                    self.foreground = true;
                    response.result = 0;
                },
                else => {},
            },
            .application_functions => switch (request.command_id) {
                40 => {
                    response.integer(u8, 1);
                    response.result = 0;
                },
                21 => {
                    response.integer(u64, 0x00000053552d6e65);
                    response.result = 0;
                },
                else => {},
            },
            .hid => switch (request.command_id) {
                0 => {
                    try self.child(session, response, .hid_resource);
                    response.result = 0;
                },
                100 => {
                    self.hid_style = try request.integer(u32, 0);
                    response.result = 0;
                },
                101 => {
                    response.integer(u32, self.hid_style);
                    response.result = 0;
                },
                102 => {
                    const buffer = request.inputBuffer() orelse return;
                    if (buffer.size == 0 or buffer.size > 40 or buffer.size % 4 != 0) return;
                    var ids: [40]u8 = undefined;
                    try memory.read(buffer.address, ids[0..buffer.size]);
                    for (0..buffer.size / 4) |i| {
                        const id = std.mem.readInt(u32, ids[i * 4 ..][0..4], .little);
                        if (id > 7 and id != 0x20 and id != 0x10) return;
                    }
                    response.result = 0;
                },
                103, 109 => {
                    self.hid_active = true;
                    response.result = 0;
                },
                104 => {
                    self.hid_active = false;
                    response.result = 0;
                },
                106 => {
                    response.copy_handle = try self.createEvent(false);
                    response.result = 0;
                },
                122, 124 => {
                    const id = try request.integer(u32, 0);
                    if (id >= self.hid_assignment.len) return;
                    self.hid_assignment[id] = if (request.command_id == 122) 1 else 2;
                    response.result = 0;
                },
                else => {},
            },
            .hid_resource => switch (request.command_id) {
                0 => {
                    if (self.hid_shared == null) self.hid_shared = try self.newShared(0x40000);
                    response.copy_handle = try self.allocate(.{ .shared = self.hid_shared.? });
                    response.result = 0;
                },
                else => {},
            },
            .time => {
                const child_kind: ?SessionKind = switch (request.command_id) {
                    0, 1, 4 => .system_clock,
                    2 => .steady_clock,
                    3 => .timezone,
                    else => null,
                };
                if (child_kind) |value| {
                    try self.child(session, response, value);
                    response.result = 0;
                }
            },
            .system_clock => switch (request.command_id) {
                0 => {
                    response.integer(i64, self.unix_time + @as(i64, @intCast(self.elapsed_ns / 1_000_000_000)));
                    response.result = 0;
                },
                2 => {
                    response.integer(i64, self.unix_time);
                    response.integer(i64, @intCast(self.elapsed_ns / 1_000_000_000));
                    response.integer(u64, 0x5a494749554d0001);
                    response.integer(u64, 0);
                    response.result = 0;
                },
                else => {},
            },
            .steady_clock => switch (request.command_id) {
                0 => {
                    response.integer(i64, @intCast(self.elapsed_ns / 1_000_000_000));
                    response.integer(u64, 0x5a494749554d0001);
                    response.integer(u64, 0);
                    response.result = 0;
                },
                else => {},
            },
            .fsp => switch (request.command_id) {
                1 => {
                    if (request.send_pid) response.result = 0;
                },
                18 => {
                    try self.child(session, response, .filesystem);
                    response.result = 0;
                },
                else => {},
            },
            .filesystem => switch (request.command_id) {
                7, 9, 10 => response.result = Result.path_not_found,
                else => {},
            },
            .set => switch (request.command_id) {
                0 => {
                    response.integer(u64, 0x00000053552d6e65);
                    response.result = 0;
                },
                else => {},
            },
            .setsys => switch (request.command_id) {
                3 => {
                    const buffer = request.outputBuffer() orelse return;
                    if (buffer.size < 0x100) return;
                    var firmware: [0x100]u8 = @splat(0);
                    firmware[0] = 3;
                    @memcpy(firmware[8..10], "NX");
                    @memcpy(firmware[0x68..0x6d], "3.0.0");
                    try memory.write(buffer.address, &firmware);
                    response.result = 0;
                },
                else => {},
            },
            .vi => switch (request.command_id) {
                0, 1, 2 => {
                    try self.child(session, response, .vi_display);
                    response.result = 0;
                },
                else => {},
            },
            .vi_display => switch (request.command_id) {
                100, 103 => {
                    try self.child(session, response, .binder);
                    response.result = 0;
                },
                101 => {
                    try self.child(session, response, .vi_system);
                    response.result = 0;
                },
                102 => {
                    try self.child(session, response, .vi_manager);
                    response.result = 0;
                },
                1010 => {
                    if (request.payload_end - request.payload_offset < 64) return;
                    if (!std.mem.startsWith(u8, request.bytes[request.payload_offset..request.payload_end], "Default\x00")) return;
                    self.display_open = true;
                    response.integer(u64, 1);
                    response.result = 0;
                },
                1020 => {
                    if (try request.integer(u64, 0) != 1) return;
                    self.display_open = false;
                    response.result = 0;
                },
                1102 => {
                    if (try request.integer(u64, 0) != 1) return;
                    response.integer(i64, 1280);
                    response.integer(i64, 720);
                    response.result = 0;
                },
                2020 => {
                    if (try request.integer(u64, 64) != 1 or !self.layer_open) return;
                    response.integer(u64, try nativeWindow(memory, request));
                    response.result = 0;
                },
                2030 => {
                    if (try request.integer(u64, 8) != 1 or !self.display_open) return;
                    self.layer_open = true;
                    response.integer(u64, 1);
                    response.integer(u64, try nativeWindow(memory, request));
                    response.result = 0;
                },
                2021, 2031 => {
                    if (try request.integer(u64, 0) != 1) return;
                    self.layer_open = false;
                    response.result = 0;
                },
                2101 => {
                    if (try request.integer(u64, 8) != 1) return;
                    self.layer_scaling = try request.integer(u32, 0);
                    response.result = 0;
                },
                5202 => {
                    if (try request.integer(u64, 0) != 1) return;
                    if (self.vsync_event) |event| response.copy_handle = try self.allocate(.{ .event = event }) else {
                        const event_handle = try self.createEvent(true);
                        self.vsync_event = (try self.get(event_handle)).event;
                        response.copy_handle = event_handle;
                    }
                    response.result = 0;
                },
                else => {},
            },
            .vi_manager => switch (request.command_id) {
                2010 => {
                    if (try request.integer(u64, 8) != 1) return;
                    self.layer_open = true;
                    response.integer(u64, 1);
                    response.result = 0;
                },
                2011 => {
                    if (try request.integer(u64, 0) != 1) return;
                    self.layer_open = false;
                    response.result = 0;
                },
                else => {},
            },
            .binder => switch (request.command_id) {
                0, 3 => try self.transact(memory, request, response),
                1 => {
                    if (try request.integer(u32, 0) != 1) return;
                    const delta = try request.integer(i32, 4);
                    const reference_type = try request.integer(u32, 8);
                    const count = switch (reference_type) {
                        0 => &self.binder_weak_refs,
                        1 => &self.binder_strong_refs,
                        else => return,
                    };
                    const next = std.math.add(i32, count.*, delta) catch return;
                    if (next < 0) return;
                    count.* = next;
                    response.result = 0;
                },
                2 => {
                    if (try request.integer(u32, 0) != 1) return;
                    response.copy_handle = try self.createEvent(true);
                    response.result = 0;
                },
                else => {},
            },
            .nvdrv => try self.nvidia(memory, request, response),
            else => {},
        }
    }

    fn control(self: *Services, handle: u32, session: *Session, request: *const ipc.Request, response: *ipc.Response) !void {
        response.result = Result.not_implemented;
        switch (request.command_id) {
            0 => {
                if (session.domain != null or self.domains.items.len >= 16) return;
                const domain = try self.allocator.create(Domain);
                errdefer self.allocator.destroy(domain);
                domain.* = .{};
                domain.objects[0] = session.kind;
                try self.domains.append(self.allocator, domain);
                session.domain = domain;
                response.integer(u32, 1);
                response.result = 0;
            },
            1 => {
                const object_id = try request.integer(u32, 0);
                const domain = session.domain orelse return;
                if (object_id == 0 or object_id > domain.count) return;
                const kind = domain.objects[object_id - 1] orelse return;
                response.move_handle = try self.allocate(.{ .session = .{ .kind = kind } });
                response.result = 0;
            },
            2, 4 => {
                const object = (try self.get(handle)).*;
                response.move_handle = try self.allocate(object);
                response.result = 0;
            },
            3 => {
                response.integer(u16, 0);
                response.result = 0;
            },
            else => {},
        }
    }

    pub fn send(self: *Services, memory: *Memory, address: u64, handle: u32) !u32 {
        const object = self.get(handle) catch return Result.invalid_handle;
        const session = switch (object.*) {
            .session => |*value| value,
            else => return Result.invalid_handle,
        };
        const request = ipc.parse(memory, address, session.domain != null) catch return Result.invalid_address;
        self.request_count += 1;
        for (request.copy_handles[0..request.copy_count]) |copied| {
            if (copied != 0xffff8001 and copied != 0xffff8000 and copied != 0x100) _ = self.get(copied) catch return Result.invalid_handle;
        }
        for (request.move_handles[0..request.move_count]) |moved| _ = self.get(moved) catch return Result.invalid_handle;
        if (request.message_type == 2) {
            try self.close(handle);
            return 0;
        }
        self.last_session = session.kind;
        self.last_command = request.command_id;
        var response: ipc.Response = .{};
        const is_control = request.message_type == 5 or request.message_type == 7;
        if (is_control) {
            try self.control(handle, session, &request, &response);
        } else if (request.message_type == 4 or request.message_type == 6) {
            var kind = session.kind;
            if (session.domain) |domain| {
                if (request.domain_object == 0 or request.domain_object > domain.count) return Result.invalid_handle;
                kind = domain.objects[request.domain_object - 1] orelse return Result.invalid_handle;
                if (request.domain_type == 2) {
                    domain.objects[request.domain_object - 1] = null;
                    return 0;
                }
                if (request.domain_type != 1) return Result.invalid_address;
            }
            self.last_session = kind;
            self.command(memory, session, kind, &request, &response) catch |err| switch (err) {
                error.InvalidIpc => response.result = Result.invalid_size,
                else => return err,
            };
        } else return Result.not_implemented;
        self.last_result = response.result;
        const empty_sm_probe = self.last_session == .sm and request.command_id == 1 and response.result == Result.service_not_found and (request.integer(u64, 0) catch 1) == 0;
        if (response.result != 0 and !empty_sm_probe) {
            self.last_failure_session = self.last_session;
            self.last_failure_command = request.command_id;
            self.last_failure_result = response.result;
        }
        if (self.trace) std.debug.print("IPC {s} command={d} result=0x{x} pid={} domain={d}\n", .{ @tagName(self.last_session), request.command_id, response.result, request.send_pid, request.domain_object });
        try ipc.respond(memory, address, &request, &response, session.domain != null and !is_control);
        return 0;
    }
};

fn makeRequest(memory: *Memory, address: u64, command_id: u32, input: []const u8, pid: bool, control: bool) !void {
    var bytes: [ipc.message_size]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], if (control) 5 else 4, .little);
    std.mem.writeInt(u32, bytes[4..8], @as(u32, @intCast((32 + input.len + 3) / 4)) | (if (pid) @as(u32, 1 << 31) else 0), .little);
    var aligned: usize = 16;
    if (pid) {
        std.mem.writeInt(u32, bytes[8..12], 1, .little);
        aligned = 32;
    }
    std.mem.writeInt(u32, bytes[aligned..][0..4], 0x49434653, .little);
    std.mem.writeInt(u32, bytes[aligned + 8 ..][0..4], command_id, .little);
    @memcpy(bytes[aligned + 16 ..][0..input.len], input);
    try memory.write(address, &bytes);
}

test "SM discovery returns live typed moved handles and unsupported service errors" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    const sm = try services.connect("sm:");
    try makeRequest(&memory, 0x1000, 1, &(@as([8]u8, @splat(0))), false, false);
    _ = try services.send(&memory, 0x1000, sm);
    try std.testing.expectEqual(Result.service_not_found, try memory.readInt(u32, 0x1018));
    try std.testing.expect(!services.registered);
    try std.testing.expectEqual(@as(u32, 0), services.last_failure_result);
    try makeRequest(&memory, 0x1000, 0, &(@as([8]u8, @splat(0))), true, false);
    try std.testing.expectEqual(@as(u32, 0), try services.send(&memory, 0x1000, sm));
    try std.testing.expect(services.registered);
    try makeRequest(&memory, 0x1000, 1, "apm\x00\x00\x00\x00\x00", false, false);
    _ = try services.send(&memory, 0x1000, sm);
    const apm = try memory.readInt(u32, 0x100c);
    try std.testing.expectEqual(SessionKind.apm, (try services.get(apm)).session.kind);
    try makeRequest(&memory, 0x1000, 1, "missing\x00", false, false);
    _ = try services.send(&memory, 0x1000, sm);
    try std.testing.expectEqual(Result.service_not_found, try memory.readInt(u32, 0x1018));
    try std.testing.expectEqual(Result.service_not_found, services.last_failure_result);
    try services.close(apm);
    try std.testing.expectError(error.InvalidHandle, services.get(apm));
}

test "APM session stores distinct mode configurations and rejects invalid mode" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    const session = try services.allocate(.{ .session = .{ .kind = .apm_session } });
    var input: [8]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], 1, .little);
    std.mem.writeInt(u32, input[4..8], 0x1234, .little);
    try makeRequest(&memory, 0x1000, 0, &input, false, false);
    _ = try services.send(&memory, 0x1000, session);
    try makeRequest(&memory, 0x1000, 1, input[0..4], false, false);
    _ = try services.send(&memory, 0x1000, session);
    try std.testing.expectEqual(@as(u32, 0x1234), try memory.readInt(u32, 0x1020));
    try std.testing.expectEqual(@as(u32, 0x10000), services.performance_config[0]);
    std.mem.writeInt(u32, input[0..4], 2, .little);
    try makeRequest(&memory, 0x1000, 1, input[0..4], false, false);
    _ = try services.send(&memory, 0x1000, session);
    try std.testing.expectEqual(@as(u32, 0xf001), try memory.readInt(u32, 0x1018));
}

test "closed handles cannot address reused slots and event clones share state" {
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    const first = try services.createEvent(false);
    const clone = try services.allocate((try services.get(first)).*);
    try services.signalEvent(first);
    try std.testing.expect(try services.isSignaled(clone));
    try services.close(first);
    const other = try services.createEvent(false);
    try std.testing.expect(other != first);
    try std.testing.expectError(error.InvalidHandle, services.get(first));
    try services.resetEvent(clone);
    try std.testing.expect(!try services.isSignaled(clone));
}

test "service handle allocation stays below the thread namespace" {
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    services.next_handle = 0x7fffffff;
    try std.testing.expectEqual(@as(u32, 0x7fffffff), try services.allocate(.{ .session = .{ .kind = .sm } }));
    try std.testing.expectError(error.HandleLimit, services.allocate(.{ .session = .{ .kind = .sm } }));
}

test "shared mappings preserve read only guest permissions while host samples update" {
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    const shared = try services.newShared(0x1000);
    const handle = try services.allocate(.{ .shared = shared });
    try services.mapShared(&memory, handle, 0x8000, 0x1000, 1);
    shared.bytes[0] = 42;
    try services.syncShared(&memory);
    try std.testing.expectEqual(@as(u8, 42), try memory.readInt(u8, 0x8000));
    try std.testing.expectError(error.AccessDenied, memory.writeInt(u8, 0x8000, 0));
    try std.testing.expectError(error.InvalidMapping, services.mapShared(&memory, handle, 0xa000, 0x2000, 1));
}

test "domain conversion and clone control produce valid objects without domain control replies" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    const handle = try services.allocate(.{ .session = .{ .kind = .fsp } });
    try makeRequest(&memory, 0x1000, 0, &.{}, false, true);
    _ = try services.send(&memory, 0x1000, handle);
    try std.testing.expectEqual(@as(u32, 1), try memory.readInt(u32, 0x1020));
    try std.testing.expect((try services.get(handle)).session.domain != null);
    try makeRequest(&memory, 0x1000, 2, &.{}, false, true);
    _ = try services.send(&memory, 0x1000, handle);
    const clone = try memory.readInt(u32, 0x100c);
    try std.testing.expectEqual((try services.get(handle)).session.domain, (try services.get(clone)).session.domain);
}

test "legacy focus notification is consumed once and copied events retain shared state" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true });
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    const handle = try services.allocate(.{ .session = .{ .kind = .common_state } });
    try makeRequest(&memory, 0x1000, 0, &.{}, false, false);
    _ = try services.send(&memory, 0x1000, handle);
    const event = try memory.readInt(u32, 0x100c);
    try std.testing.expect(try services.isSignaled(event));
    try makeRequest(&memory, 0x1000, 1, &.{}, false, false);
    _ = try services.send(&memory, 0x1000, handle);
    try std.testing.expectEqual(@as(u32, 0xf), try memory.readInt(u32, 0x1020));
    try std.testing.expect(!try services.isSignaled(event));
    try makeRequest(&memory, 0x1000, 1, &.{}, false, false);
    _ = try services.send(&memory, 0x1000, handle);
    try std.testing.expectEqual(Result.am_no_message, try memory.readInt(u32, 0x1018));
}

test "NvMap validates CPU backing and GPU padding never enlarges accessible backing" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x3000, 0x1000, .{ .read = true, .write = true });
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    services.nv_files[0] = .{ .id = 1, .device = .nvmap };
    services.nv_files[1] = .{ .id = 2, .device = .address_space };
    var create: [8]u8 = @splat(0);
    std.mem.writeInt(u32, create[0..4], 0x1000, .little);
    try std.testing.expectEqual(@as(u32, 0), try services.ioctl(&memory, 1, 0xc0080101, &create));
    const handle = std.mem.readInt(u32, create[4..8], .little);
    var allocate: [32]u8 = @splat(0);
    std.mem.writeInt(u32, allocate[0..4], handle, .little);
    std.mem.writeInt(u32, allocate[12..16], 0x20000, .little);
    std.mem.writeInt(u64, allocate[24..32], 0xa000, .little);
    try std.testing.expectError(error.InvalidIpc, services.ioctl(&memory, 1, 0xc0200104, &allocate));
    try std.testing.expect(!(try services.mapByHandle(handle)).allocated);
    std.mem.writeInt(u64, allocate[24..32], 0x3000, .little);
    try std.testing.expectEqual(@as(u32, 0), try services.ioctl(&memory, 1, 0xc0200104, &allocate));
    var mapping: [40]u8 = @splat(0);
    std.mem.writeInt(u32, mapping[8..12], handle, .little);
    std.mem.writeInt(u32, mapping[12..16], 0x10000, .little);
    std.mem.writeInt(u64, mapping[24..32], 0x10000, .little);
    try std.testing.expectEqual(@as(u32, 0), try services.ioctl(&memory, 2, 0xc0284106, &mapping));
    try std.testing.expectEqual(@as(usize, 0x10000), services.gpu_mappings[0].?.size);
    try std.testing.expectEqual(@as(usize, 0x1000), services.gpu_mappings[0].?.backing_size);
    std.mem.writeInt(u32, mapping[0..4], 1, .little);
    std.mem.writeInt(u64, mapping[32..40], std.math.maxInt(u64), .little);
    try std.testing.expectEqual(@as(u32, 4), try services.ioctl(&memory, 2, 0xc0284106, &mapping));
    try std.testing.expectEqual(@as(u32, 1), try services.ioctl(&memory, 1, 0xc00401ff, mapping[0..4]));
}

test "legacy HID rings wrap with paired sampling counters and released buttons" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    services.hid_shared = try services.newShared(0x40000);
    const handle = try services.allocate(.{ .shared = services.hid_shared.? });
    try services.mapShared(&memory, handle, 0x100000, 0x40000, 1);
    for (0..18) |_| try services.updateInput(&memory, 1, 40000, -40000);
    const layout = 0x100000 + 0x9a00 + 0x28 + 6 * 0x350;
    try std.testing.expectEqual(@as(u64, 1), try memory.readInt(u64, layout + 16));
    const entry = layout + 0x20 + 0x30;
    try std.testing.expectEqual(@as(u64, 18), try memory.readInt(u64, entry));
    try std.testing.expectEqual(@as(u64, 18), try memory.readInt(u64, entry + 8));
    try std.testing.expectEqual(@as(u64, 1), try memory.readInt(u64, entry + 16));
    try std.testing.expectEqual(@as(i32, 32767), try memory.readInt(i32, entry + 24));
    try std.testing.expectEqual(@as(i32, -32767), try memory.readInt(i32, entry + 28));
    try services.updateInput(&memory, 0, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), try memory.readInt(u64, entry + 0x30 + 16));
    try std.testing.expect(!(try memory.query(layout)).permissions.write);
}

fn producerParcel() !ipc.Parcel {
    var parcel: ipc.Parcel = .{};
    const name = "android.gui.IGraphicBufferProducer";
    try parcel.put(u32, 0x100);
    try parcel.put(u32, name.len);
    for (name) |character| try parcel.put(u16, character);
    try parcel.put(u16, 0);
    parcel.end = std.mem.alignForward(usize, parcel.end, 4);
    return parcel;
}

fn producerTransact(services: *Services, memory: *Memory, transaction: u32, parcel: *ipc.Parcel) !ipc.Response {
    try parcel.write(memory, .{ .address = 0x2000, .size = 1024 });
    var input: ipc.Request = .{ .bytes = @splat(0), .message_type = 4, .payload_offset = 0, .payload_end = 12, .send_count = 1, .receive_count = 1 };
    input.sends[0] = .{ .address = 0x2000, .size = parcel.end };
    input.receives[0] = .{ .address = 0x2800, .size = 1024 };
    std.mem.writeInt(u32, input.bytes[0..4], 1, .little);
    std.mem.writeInt(u32, input.bytes[4..8], transaction, .little);
    var response: ipc.Response = .{ .result = Result.not_implemented };
    try services.transact(memory, &input, &response);
    return response;
}

test "Binder validates registered buffers and captures guest frame only after dequeue" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x2000, 0x2000, .{ .read = true, .write = true });
    var services = Services.init(std.testing.allocator);
    defer services.deinit();
    services.nvmap[0] = .{ .handle = 1, .size = 0x1000, .address = 0x3000, .allocated = true };
    var connect_parcel = try producerParcel();
    try connect_parcel.put(u32, 0);
    try connect_parcel.put(u32, 2);
    try connect_parcel.put(u32, 0);
    try std.testing.expectEqual(@as(u32, 0), (try producerTransact(&services, &memory, 10, &connect_parcel)).result);
    var graphic: [364]u8 = @splat(0);
    std.mem.writeInt(u32, graphic[0..4], 0x47424652, .little);
    std.mem.writeInt(u32, graphic[4..8], 8, .little);
    std.mem.writeInt(u32, graphic[8..12], 8, .little);
    std.mem.writeInt(u32, graphic[12..16], 16, .little);
    std.mem.writeInt(u32, graphic[16..20], 1, .little);
    std.mem.writeInt(u32, graphic[44..48], 1, .little);
    std.mem.writeInt(u32, graphic[80..84], 0x1000, .little);
    std.mem.writeInt(u32, graphic[112..116], 64, .little);
    std.mem.writeInt(u32, graphic[128..132], 0, .little);
    var preallocate = try producerParcel();
    try preallocate.put(u32, 0);
    try preallocate.put(u32, 1);
    try preallocate.putObject(&graphic);
    try std.testing.expectEqual(@as(u32, 0), (try producerTransact(&services, &memory, 14, &preallocate)).result);
    var parameters: [84]u8 = @splat(0);
    std.mem.writeInt(u32, parameters[32..36], 2, .little);
    var queue_before = try producerParcel();
    try queue_before.put(u32, 0);
    try queue_before.putObject(&parameters);
    try std.testing.expectEqual(Result.not_implemented, (try producerTransact(&services, &memory, 7, &queue_before)).result);
    try std.testing.expectEqual(@as(u64, 0), services.frame_sequence);
    var dequeue = try producerParcel();
    for ([_]u32{ 0, 8, 8, 1, 0x300 }) |value| try dequeue.put(u32, value);
    try std.testing.expectEqual(@as(u32, 0), (try producerTransact(&services, &memory, 3, &dequeue)).result);
    var queue_after = try producerParcel();
    try queue_after.put(u32, 0);
    try queue_after.putObject(&parameters);
    try std.testing.expectEqual(@as(u32, 0), (try producerTransact(&services, &memory, 7, &queue_after)).result);
    const frame = services.latest_frame.?;
    try std.testing.expectEqual(@as(u64, 0x3000), frame.cpu_address);
    try std.testing.expectEqual(@as(u64, 1), frame.sequence);
    try std.testing.expectEqual(@as(u32, 16), frame.stride);
    try std.testing.expect(frame.flip_v);
    try std.testing.expectEqual(BufferState.free, services.binder_buffers[0].?.state);
    var duplicate_queue = try producerParcel();
    try duplicate_queue.put(u32, 0);
    try duplicate_queue.putObject(&parameters);
    try std.testing.expectEqual(Result.not_implemented, (try producerTransact(&services, &memory, 7, &duplicate_queue)).result);
    try std.testing.expectEqual(@as(u64, 1), services.frame_sequence);
}
