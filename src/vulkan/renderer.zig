const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @import("vulkan_c") else struct {};

pub const Renderer = if (builtin.os.tag == .windows) WindowsRenderer else UnsupportedRenderer;

const UnsupportedRenderer = struct {
    width: u32 = 0,
    height: u32 = 0,
    frames: u64 = 0,

    pub fn init(_: std.mem.Allocator, _: usize, _: usize, _: u32, _: u32) !UnsupportedRenderer {
        return error.UnsupportedPlatform;
    }
    pub fn present(_: *UnsupportedRenderer, _: []const u32, _: u32, _: u32) !void {
        return error.UnsupportedPlatform;
    }
    pub fn resize(_: *UnsupportedRenderer, _: u32, _: u32) !void {
        return error.UnsupportedPlatform;
    }
    pub fn readback(_: *UnsupportedRenderer, _: std.mem.Allocator) ![]u8 {
        return error.UnsupportedPlatform;
    }
    pub fn deinit(_: *UnsupportedRenderer) void {}
};

fn check(result: c.VkResult, failure: anyerror) !void {
    if (result != c.VK_SUCCESS) {
        std.debug.print("Vulkan {s}: result={d}\n", .{ @errorName(failure), result });
        return failure;
    }
}

const Buffer = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    mapped: ?*anyopaque = null,
    size: usize = 0,

    fn deinit(self: *Buffer, device: c.VkDevice) void {
        if (self.mapped != null) c.vkUnmapMemory(device, self.memory);
        if (self.buffer != null) c.vkDestroyBuffer(device, self.buffer, null);
        if (self.memory != null) c.vkFreeMemory(device, self.memory, null);
        self.* = .{};
    }
};

const WindowsRenderer = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    queue_family: u32 = 0,
    command_pool: c.VkCommandPool = null,
    command: c.VkCommandBuffer = null,
    acquire_semaphore: c.VkSemaphore = null,
    fence: c.VkFence = null,
    swapchain: c.VkSwapchainKHR = null,
    images: []c.VkImage = &.{},
    present_semaphores: []c.VkSemaphore = &.{},
    upload: Buffer = .{},
    capture: Buffer = .{},
    format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    width: u32 = 0,
    height: u32 = 0,
    frames: u64 = 0,
    capture_valid: bool = false,
    failed: bool = false,
    device_name: [256]u8 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, hinstance: usize, hwnd: usize, width: u32, height: u32) !WindowsRenderer {
        if (hinstance == 0 or hwnd == 0) return error.InvalidWindow;
        var self: WindowsRenderer = .{ .allocator = allocator };
        errdefer self.deinit();
        const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface" };
        var app = std.mem.zeroes(c.VkApplicationInfo);
        app.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app.pApplicationName = "Zigium";
        app.applicationVersion = 1;
        app.pEngineName = "Zigium Vulkan";
        app.apiVersion = c.VK_API_VERSION_1_0;
        var instance_info = std.mem.zeroes(c.VkInstanceCreateInfo);
        instance_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instance_info.pApplicationInfo = &app;
        instance_info.enabledExtensionCount = extensions.len;
        instance_info.ppEnabledExtensionNames = &extensions;
        try check(c.vkCreateInstance(&instance_info, null, &self.instance), error.VulkanInstance);
        var surface_info = std.mem.zeroes(c.VkWin32SurfaceCreateInfoKHR);
        surface_info.sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
        surface_info.hinstance = @ptrFromInt(hinstance);
        surface_info.hwnd = @ptrFromInt(hwnd);
        try check(c.vkCreateWin32SurfaceKHR(self.instance, &surface_info, null, &self.surface), error.VulkanSurface);
        try self.selectDevice();
        var properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        @memcpy(&self.device_name, &properties.deviceName);
        const priority: f32 = 1;
        var queue_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = self.queue_family;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;
        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var device_info = std.mem.zeroes(c.VkDeviceCreateInfo);
        device_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        device_info.enabledExtensionCount = device_extensions.len;
        device_info.ppEnabledExtensionNames = &device_extensions;
        try check(c.vkCreateDevice(self.physical_device, &device_info, null, &self.device), error.VulkanDevice);
        c.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = self.queue_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try check(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool), error.VulkanCommandPool);
        var command_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        command_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        command_info.commandPool = self.command_pool;
        command_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        command_info.commandBufferCount = 1;
        try check(c.vkAllocateCommandBuffers(self.device, &command_info, &self.command), error.VulkanCommandBuffer);
        self.acquire_semaphore = try self.createSemaphore();
        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        try check(c.vkCreateFence(self.device, &fence_info, null, &self.fence), error.VulkanFence);
        try self.resize(width, height);
        return self;
    }

    fn selectDevice(self: *WindowsRenderer) !void {
        var count: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, null), error.VulkanDeviceEnumeration);
        if (count == 0) return error.NoVulkanDevice;
        const devices = try self.allocator.alloc(c.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr), error.VulkanDeviceEnumeration);
        for (devices[0..count]) |physical| {
            if (!try self.supportsSwapchain(physical)) continue;
            var family_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
            const families = try self.allocator.alloc(c.VkQueueFamilyProperties, family_count);
            defer self.allocator.free(families);
            c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, families.ptr);
            for (families[0..family_count], 0..) |family, index| {
                if (family.queueCount == 0 or family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                var supported: c.VkBool32 = c.VK_FALSE;
                try check(c.vkGetPhysicalDeviceSurfaceSupportKHR(physical, @intCast(index), self.surface, &supported), error.VulkanSurfaceSupport);
                if (supported == c.VK_TRUE) {
                    self.physical_device = physical;
                    self.queue_family = @intCast(index);
                    return;
                }
            }
        }
        return error.NoPresentQueue;
    }

    fn supportsSwapchain(self: *WindowsRenderer, physical: c.VkPhysicalDevice) !bool {
        var count: u32 = 0;
        try check(c.vkEnumerateDeviceExtensionProperties(physical, null, &count, null), error.VulkanExtensionEnumeration);
        const extensions = try self.allocator.alloc(c.VkExtensionProperties, count);
        defer self.allocator.free(extensions);
        try check(c.vkEnumerateDeviceExtensionProperties(physical, null, &count, extensions.ptr), error.VulkanExtensionEnumeration);
        for (extensions[0..count]) |extension| {
            if (std.mem.eql(u8, std.mem.sliceTo(&extension.extensionName, 0), "VK_KHR_swapchain")) return true;
        }
        return false;
    }

    fn createSemaphore(self: *WindowsRenderer) !c.VkSemaphore {
        var info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        var semaphore: c.VkSemaphore = null;
        try check(c.vkCreateSemaphore(self.device, &info, null, &semaphore), error.VulkanSemaphore);
        return semaphore;
    }

    fn createBuffer(self: *WindowsRenderer, size: usize, usage: c.VkBufferUsageFlags) !Buffer {
        var buffer: Buffer = .{ .size = size };
        errdefer buffer.deinit(self.device);
        var info = std.mem.zeroes(c.VkBufferCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage;
        info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try check(c.vkCreateBuffer(self.device, &info, null, &buffer.buffer), error.VulkanBuffer);
        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buffer.buffer, &requirements);
        var properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &properties);
        var memory_type: ?u32 = null;
        const flags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        for (properties.memoryTypes[0..properties.memoryTypeCount], 0..) |memory, index| {
            if (requirements.memoryTypeBits & (@as(u32, 1) << @intCast(index)) != 0 and memory.propertyFlags & flags == flags) {
                memory_type = @intCast(index);
                break;
            }
        }
        var allocation = std.mem.zeroes(c.VkMemoryAllocateInfo);
        allocation.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memory_type orelse return error.NoCoherentHostMemory;
        try check(c.vkAllocateMemory(self.device, &allocation, null, &buffer.memory), error.VulkanMemory);
        try check(c.vkBindBufferMemory(self.device, buffer.buffer, buffer.memory, 0), error.VulkanBufferBinding);
        try check(c.vkMapMemory(self.device, buffer.memory, 0, size, 0, &buffer.mapped), error.VulkanMemoryMap);
        return buffer;
    }

    pub fn resize(self: *WindowsRenderer, width: u32, height: u32) !void {
        if (self.failed) return error.RendererFailed;
        try check(c.vkDeviceWaitIdle(self.device), error.VulkanWaitIdle);
        self.destroySwapchain();
        if (width == 0 or height == 0) return;
        errdefer self.destroySwapchain();
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities), error.VulkanSurfaceCapabilities);
        if (capabilities.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_DST_BIT == 0) return error.SurfaceCannotReceivePixels;
        var format_count: u32 = 0;
        try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null), error.VulkanSurfaceFormats);
        if (format_count == 0) return error.NoSurfaceFormat;
        const formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr), error.VulkanSurfaceFormats);
        const preferred = [_]c.VkFormat{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_FORMAT_B8G8R8A8_SRGB, c.VK_FORMAT_R8G8B8A8_SRGB };
        var chosen: ?c.VkSurfaceFormatKHR = null;
        if (format_count == 1 and formats[0].format == c.VK_FORMAT_UNDEFINED) {
            chosen = .{ .format = preferred[0], .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR };
        } else search: for (preferred) |candidate| {
            for (formats[0..format_count]) |format| {
                if (format.format == candidate and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                    chosen = format;
                    break :search;
                }
            }
        }
        const surface_format = chosen orelse return error.UnsupportedSurfaceFormat;
        const extent = if (capabilities.currentExtent.width != std.math.maxInt(u32)) capabilities.currentExtent else c.VkExtent2D{
            .width = std.math.clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
            .height = std.math.clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
        };
        if (extent.width == 0 or extent.height == 0) return;
        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount != 0) image_count = @min(image_count, capabilities.maxImageCount);
        const capture_available = capabilities.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT != 0;
        var info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        info.surface = self.surface;
        info.minImageCount = image_count;
        info.imageFormat = surface_format.format;
        info.imageColorSpace = surface_format.colorSpace;
        info.imageExtent = extent;
        info.imageArrayLayers = 1;
        info.imageUsage = @as(u32, c.VK_IMAGE_USAGE_TRANSFER_DST_BIT) | (if (capture_available) @as(u32, c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) else @as(u32, 0));
        info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = capabilities.currentTransform;
        info.compositeAlpha = selectCompositeAlpha(capabilities.supportedCompositeAlpha);
        info.presentMode = c.VK_PRESENT_MODE_FIFO_KHR;
        info.clipped = c.VK_TRUE;
        try check(c.vkCreateSwapchainKHR(self.device, &info, null, &self.swapchain), error.VulkanSwapchain);
        try check(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &image_count, null), error.VulkanSwapchainImages);
        self.images = try self.allocator.alloc(c.VkImage, image_count);
        try check(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &image_count, self.images.ptr), error.VulkanSwapchainImages);
        if (image_count != self.images.len) return error.SwapchainImageCountChanged;
        self.present_semaphores = try self.allocator.alloc(c.VkSemaphore, image_count);
        @memset(self.present_semaphores, null);
        for (self.present_semaphores) |*semaphore| semaphore.* = try self.createSemaphore();
        const pixels = try std.math.mul(usize, extent.width, extent.height);
        const bytes = try std.math.mul(usize, pixels, 4);
        if (bytes > 256 * 1024 * 1024) return error.FrameTooLarge;
        self.upload = try self.createBuffer(bytes, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        if (capture_available) self.capture = try self.createBuffer(bytes, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        self.width = extent.width;
        self.height = extent.height;
        self.format = surface_format.format;
    }

    fn selectCompositeAlpha(supported: c.VkCompositeAlphaFlagsKHR) c.VkCompositeAlphaFlagBitsKHR {
        const choices = [_]c.VkCompositeAlphaFlagBitsKHR{ c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR, c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR, c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR };
        for (choices) |choice| if (supported & choice != 0) return choice;
        return c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    }

    fn rgba(self: *const WindowsRenderer) bool {
        return self.format == c.VK_FORMAT_R8G8B8A8_UNORM or self.format == c.VK_FORMAT_R8G8B8A8_SRGB;
    }

    fn converted(pixel: u32) u32 {
        return (pixel & 0xff00ff00) | ((pixel & 0xff) << 16) | ((pixel >> 16) & 0xff);
    }

    fn uploadPixels(self: *WindowsRenderer, pixels: []const u32, width: u32, height: u32) void {
        const target: [*]u32 = @ptrCast(@alignCast(self.upload.mapped.?));
        if (width == self.width and height == self.height and !self.rgba()) {
            @memcpy(target[0..pixels.len], pixels);
            return;
        }
        for (0..self.height) |y| {
            const source_y = y * @as(usize, height) / self.height;
            for (0..self.width) |x| {
                const source_x = x * @as(usize, width) / self.width;
                const pixel = pixels[source_y * width + source_x];
                target[y * self.width + x] = if (self.rgba()) converted(pixel) else pixel;
            }
        }
    }

    fn barrier(self: *WindowsRenderer, image: c.VkImage, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout, source_access: c.VkAccessFlags, destination_access: c.VkAccessFlags, source_stage: c.VkPipelineStageFlags, destination_stage: c.VkPipelineStageFlags) void {
        var image_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        image_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        image_barrier.srcAccessMask = source_access;
        image_barrier.dstAccessMask = destination_access;
        image_barrier.oldLayout = old_layout;
        image_barrier.newLayout = new_layout;
        image_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        image_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        image_barrier.image = image;
        image_barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        c.vkCmdPipelineBarrier(self.command, source_stage, destination_stage, 0, 0, null, 0, null, 1, &image_barrier);
    }

    pub fn present(self: *WindowsRenderer, pixels: []const u32, width: u32, height: u32) !void {
        if (self.failed) return error.RendererFailed;
        if (width == 0 or height == 0) return;
        const pixel_count = try std.math.mul(usize, width, height);
        if (pixels.len != pixel_count) return error.InvalidPixelBuffer;
        if (self.swapchain == null) try self.resize(width, height);
        if (self.swapchain == null) return;
        try check(c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)), error.VulkanFrameWait);
        var image_index: u32 = 0;
        const acquired = c.vkAcquireNextImageKHR(self.device, self.swapchain, 1_000_000_000, self.acquire_semaphore, null, &image_index);
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.resize(width, height);
            return;
        }
        if (acquired == c.VK_TIMEOUT or acquired == c.VK_NOT_READY) return;
        if (acquired != c.VK_SUCCESS and acquired != c.VK_SUBOPTIMAL_KHR) try check(acquired, error.VulkanAcquire);
        errdefer self.failed = true;
        self.uploadPixels(pixels, width, height);
        try check(c.vkResetCommandBuffer(self.command, 0), error.VulkanCommandReset);
        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(c.vkBeginCommandBuffer(self.command, &begin_info), error.VulkanCommandBegin);
        const image = self.images[image_index];
        self.barrier(image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT);
        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 };
        c.vkCmdCopyBufferToImage(self.command, self.upload.buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        if (self.capture.buffer != null) {
            self.barrier(image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_ACCESS_TRANSFER_READ_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT);
            c.vkCmdCopyImageToBuffer(self.command, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.capture.buffer, 1, &region);
            var host_barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
            host_barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
            host_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            host_barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
            host_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            host_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            host_barrier.buffer = self.capture.buffer;
            host_barrier.size = c.VK_WHOLE_SIZE;
            c.vkCmdPipelineBarrier(self.command, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &host_barrier, 0, null);
            self.barrier(image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_ACCESS_TRANSFER_READ_BIT, 0, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
        } else {
            self.barrier(image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_ACCESS_TRANSFER_WRITE_BIT, 0, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
        }
        try check(c.vkEndCommandBuffer(self.command), error.VulkanCommandEnd);
        try check(c.vkResetFences(self.device, 1, &self.fence), error.VulkanFenceReset);
        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        var submit = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &self.acquire_semaphore;
        submit.pWaitDstStageMask = &wait_stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &self.command;
        submit.signalSemaphoreCount = 1;
        // Reacquiring this image guarantees its previous presentation wait ended.
        submit.pSignalSemaphores = &self.present_semaphores[image_index];
        try check(c.vkQueueSubmit(self.queue, 1, &submit, self.fence), error.VulkanSubmit);
        self.capture_valid = self.capture.buffer != null;
        var presentation = std.mem.zeroes(c.VkPresentInfoKHR);
        presentation.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        presentation.waitSemaphoreCount = 1;
        presentation.pWaitSemaphores = &self.present_semaphores[image_index];
        presentation.swapchainCount = 1;
        presentation.pSwapchains = &self.swapchain;
        presentation.pImageIndices = &image_index;
        const result = c.vkQueuePresentKHR(self.queue, &presentation);
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.resize(width, height);
            return;
        }
        if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) try check(result, error.VulkanPresent);
        self.frames += 1;
        if (result == c.VK_SUBOPTIMAL_KHR or acquired == c.VK_SUBOPTIMAL_KHR) try self.resize(width, height);
    }

    pub fn readback(self: *WindowsRenderer, allocator: std.mem.Allocator) ![]u8 {
        if (self.failed) return error.RendererFailed;
        if (self.capture.buffer == null) return error.ReadbackUnsupported;
        if (!self.capture_valid) return error.NoRenderedFrame;
        try check(c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)), error.VulkanReadbackWait);
        const output = try allocator.alloc(u8, self.capture.size);
        const source: [*]const u8 = @ptrCast(self.capture.mapped.?);
        @memcpy(output, source[0..output.len]);
        if (self.rgba()) {
            var offset: usize = 0;
            while (offset < output.len) : (offset += 4) std.mem.swap(u8, &output[offset], &output[offset + 2]);
        }
        return output;
    }

    fn destroySwapchain(self: *WindowsRenderer) void {
        self.upload.deinit(self.device);
        self.capture.deinit(self.device);
        for (self.present_semaphores) |semaphore| if (semaphore != null) c.vkDestroySemaphore(self.device, semaphore, null);
        self.allocator.free(self.present_semaphores);
        self.allocator.free(self.images);
        self.present_semaphores = &.{};
        self.images = &.{};
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
        self.width = 0;
        self.height = 0;
        self.capture_valid = false;
    }

    pub fn deinit(self: *WindowsRenderer) void {
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
            self.destroySwapchain();
            if (self.fence != null) c.vkDestroyFence(self.device, self.fence, null);
            if (self.acquire_semaphore != null) c.vkDestroySemaphore(self.device, self.acquire_semaphore, null);
            if (self.command_pool != null) c.vkDestroyCommandPool(self.device, self.command_pool, null);
            c.vkDestroyDevice(self.device, null);
        }
        if (self.surface != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        self.* = undefined;
    }
};
