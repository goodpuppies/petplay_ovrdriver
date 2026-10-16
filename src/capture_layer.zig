//! Optional, request-driven Vulkan image-content diagnostic in the producer process.
//! Optional static PPM controls and bounded asynchronous marker measurements.
const std = @import("std");
const linux = std.os.linux;
const v = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vk_layer.h");
});
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
var instance: v.VkInstance = null;
var physical: v.VkPhysicalDevice = null;
var device: v.VkDevice = null;
var gipa: v.PFN_vkGetInstanceProcAddr = null;
var gdpa: v.PFN_vkGetDeviceProcAddr = null;
var mutex: std.Io.Mutex = .init;
var disabled = false;
var submission_id: u64 = 0;
var directory: i32 = -1;
const max_images = 32;
const Image = struct { handle: v.VkImage = null, width: u32 = 0, height: u32 = 0, format: u32 = 0, layout: v.VkImageLayout = v.VK_IMAGE_LAYOUT_UNDEFINED, known: bool = false, external_owner: bool = false, last_queue: v.VkQueue = null, memory: v.VkDeviceMemory = null, inode: u64 = 0, submission: u64 = 0 };
var images: [max_images]Image = @splat(.{});
const Change = struct { image: v.VkImage, layout: v.VkImageLayout, external_owner: bool };
const Commands = struct { handle: v.VkCommandBuffer = null, count: usize = 0, pass: v.VkRenderPass = null, framebuffer: v.VkFramebuffer = null, changes: [max_images]Change = undefined, overflow: bool = false };
var commands: [128]Commands = @splat(.{});
const Queue = struct { handle: v.VkQueue = null, family: u32 = 0 };
var queues: [16]Queue = @splat(.{});
fn log(comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "PetPlay capture: " ++ fmt ++ "\n", args) catch return;
    _ = linux.write(2, s.ptr, s.len);
}
fn fnType(comptime name: []const u8) type {
    return @typeInfo(@field(v, "PFN_" ++ name)).optional.child;
}
fn D(comptime name: [:0]const u8) fnType(name) {
    const f = gdpa.?(device, name) orelse {
        log("missing function {s}, device={x}", .{ name, @intFromPtr(device) });
        @panic("missing next Vulkan function");
    };
    return @ptrCast(f);
}
fn I(comptime name: [:0]const u8) fnType(name) {
    return @ptrCast(gipa.?(instance, name).?);
}
fn dir() bool {
    if (directory >= 0) return true;
    const path = getenv("PP_CAPTURE_DIRECTORY") orelse return false;
    const raw = linux.openat(linux.AT.FDCWD, path, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(raw) != .SUCCESS) return false;
    const fd: i32 = @intCast(raw);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &st)) != .SUCCESS or !st.mask.MODE or !st.mask.UID or st.uid != linux.geteuid() or st.mode & 0o777 != 0o700) {
        _ = linux.close(fd);
        return false;
    }
    directory = fd;
    return true;
}
fn command(cb: v.VkCommandBuffer, create: bool) ?*Commands {
    var free: ?*Commands = null;
    for (&commands) |*x| {
        if (x.handle == cb) return x;
        if (x.handle == null) free = x;
    }
    if (create) if (free) |x| {
        x.* = .{ .handle = cb };
        return x;
    };
    return null;
}
export fn vkNegotiateLoaderLayerInterfaceVersion(p: *v.VkNegotiateLayerInterface) callconv(.c) v.VkResult {
    if (p.loaderLayerInterfaceVersion < 2) return v.VK_ERROR_INITIALIZATION_FAILED;
    p.loaderLayerInterfaceVersion = 2;
    p.pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    p.pfnGetDeviceProcAddr = vkGetDeviceProcAddr;
    p.pfnGetPhysicalDeviceProcAddr = null;
    return v.VK_SUCCESS;
}
fn hook(name: []const u8) v.PFN_vkVoidFunction {
    const list = .{ .{ "vkGetInstanceProcAddr", &vkGetInstanceProcAddr }, .{ "vkGetDeviceProcAddr", &vkGetDeviceProcAddr }, .{ "vkCreateInstance", &createInstance }, .{ "vkCreateDevice", &createDevice }, .{ "vkCreateImage", &createImage }, .{ "vkDestroyImage", &destroyImage }, .{ "vkBindImageMemory", &bindImage }, .{ "vkBindImageMemory2", &bindImage2 }, .{ "vkGetMemoryFdKHR", &memoryFd }, .{ "vkCmdEndRenderPass", &endRenderPass }, .{ "vkCmdExecuteCommands", &executeCommands }, .{ "vkCmdBeginRendering", &beginRendering }, .{ "vkCmdBeginRenderingKHR", &beginRenderingKhr }, .{ "vkCreateImageView", &createView }, .{ "vkDestroyImageView", &destroyView }, .{ "vkCreateRenderPass", &createPass }, .{ "vkCreateRenderPass2", &createPass2 }, .{ "vkCreateRenderPass2KHR", &createPass2Khr }, .{ "vkDestroyRenderPass", &destroyPass }, .{ "vkCreateFramebuffer", &createFramebuffer }, .{ "vkDestroyFramebuffer", &destroyFramebuffer }, .{ "vkCmdBeginRenderPass", &beginPass }, .{ "vkCmdBeginRenderPass2", &beginPass2 }, .{ "vkCmdBeginRenderPass2KHR", &beginPass2Khr }, .{ "vkCmdEndRenderPass2", &endPass2 }, .{ "vkCmdEndRenderPass2KHR", &endPass2Khr }, .{ "vkGetDeviceQueue", &getQueue }, .{ "vkGetDeviceQueue2", &getQueue2 }, .{ "vkBeginCommandBuffer", &beginCommands }, .{ "vkFreeCommandBuffers", &freeCommands }, .{ "vkCmdPipelineBarrier", &barrier }, .{ "vkQueueSubmit", &submit }, .{ "vkQueueSubmit2", &submit2 }, .{ "vkQueueSubmit2KHR", &submit2Khr }, .{ "vkCmdPipelineBarrier2", &barrier2 }, .{ "vkCmdPipelineBarrier2KHR", &barrier2Khr }, .{ "vkDestroyDevice", &destroyDevice } };
    inline for (list) |item| if (std.mem.eql(u8, name, item[0])) return @ptrCast(item[1]);
    return null;
}
export fn vkGetInstanceProcAddr(inst: v.VkInstance, name: [*c]const u8) callconv(.c) v.PFN_vkVoidFunction {
    const text = std.mem.span(name);
    if (std.mem.eql(u8, text, "vkGetInstanceProcAddr") or std.mem.eql(u8, text, "vkCreateInstance")) return hook(text);
    const next = if (gipa) |f| f(inst, name) else null;
    return if (next != null) hook(text) orelse next else null;
}
export fn vkGetDeviceProcAddr(dev: v.VkDevice, name: [*c]const u8) callconv(.c) v.PFN_vkVoidFunction {
    const next = if (gdpa) |f| f(dev, name) else null;
    return if (next != null) hook(std.mem.span(name)) orelse next else null;
}

fn createInstance(ci: [*c]const v.VkInstanceCreateInfo, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkInstance) callconv(.c) v.VkResult {
    var chain: [*c]v.VkLayerInstanceCreateInfo = @ptrCast(@alignCast(@constCast(ci.*.pNext)));
    while (chain != null and !(chain.*.sType == v.VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO and chain.*.function == v.VK_LAYER_LINK_INFO)) chain = @ptrCast(@alignCast(@constCast(chain.*.pNext)));
    if (chain == null) return v.VK_ERROR_INITIALIZATION_FAILED;
    const link = chain.*.u.pLayerInfo;
    gipa = link.*.pfnNextGetInstanceProcAddr;
    chain.*.u.pLayerInfo = link.*.pNext;
    const next: fnType("vkCreateInstance") = @ptrCast(gipa.?(null, "vkCreateInstance").?);
    const result = next(ci, alloc, out);
    if (result == v.VK_SUCCESS) {
        if (instance != null) disabled = true;
        instance = out.*;
    }
    return result;
}
fn createDevice(pd: v.VkPhysicalDevice, ci: [*c]const v.VkDeviceCreateInfo, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkDevice) callconv(.c) v.VkResult {
    var chain: [*c]v.VkLayerDeviceCreateInfo = @ptrCast(@alignCast(@constCast(ci.*.pNext)));
    while (chain != null and !(chain.*.sType == v.VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO and chain.*.function == v.VK_LAYER_LINK_INFO)) chain = @ptrCast(@alignCast(@constCast(chain.*.pNext)));
    if (chain == null) return v.VK_ERROR_INITIALIZATION_FAILED;
    const link = chain.*.u.pLayerInfo;
    const next: fnType("vkCreateDevice") = @ptrCast(link.*.pfnNextGetInstanceProcAddr.?(instance, "vkCreateDevice").?);
    gdpa = link.*.pfnNextGetDeviceProcAddr;
    chain.*.u.pLayerInfo = link.*.pNext;
    const result = next(pd, ci, alloc, out);
    if (result == v.VK_SUCCESS) {
        if (device != null) disabled = true;
        device = out.*;
        physical = pd;
        log("device initialized; request-driven readback, disabled={}", .{disabled});
    }
    return result;
}
fn destroyDevice(dev: v.VkDevice, alloc: [*c]const v.VkAllocationCallbacks) callconv(.c) void {
    log("destroy device={x}, tracked={x}", .{ @intFromPtr(dev), @intFromPtr(device) });
    const next: fnType("vkDestroyDevice") = @ptrCast(gdpa.?(dev, "vkDestroyDevice").?);
    stopStream();
    if (directory >= 0) {
        _ = linux.close(directory);
        directory = -1;
    }
    next(dev, alloc);
    device = null;
}
fn createImage(dev: v.VkDevice, ci: [*c]const v.VkImageCreateInfo, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkImage) callconv(.c) v.VkResult {
    const next: fnType("vkCreateImage") = @ptrCast(gdpa.?(dev, "vkCreateImage").?);
    const result = next(dev, ci, alloc, out);
    if (result != v.VK_SUCCESS or dev != device or ci.*.extent.width != 960 or ci.*.extent.height != 960 or ci.*.mipLevels != 1 or ci.*.arrayLayers != 1 or ci.*.samples != 1 or (ci.*.usage & v.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) == 0) return result;
    if (ci.*.format != 37 and ci.*.format != 43 and ci.*.format != 44 and ci.*.format != 50) return result;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    for (&images, 0..) |*im, i| if (im.handle == null) {
        im.* = .{ .handle = out.*, .width = ci.*.extent.width, .height = ci.*.extent.height, .format = ci.*.format, .layout = ci.*.initialLayout };
        log("tracking image={d} handle={x} format={d} usage={x}", .{ i, @intFromPtr(out.*), ci.*.format, ci.*.usage });
        break;
    };
    return result;
}
fn destroyImage(dev: v.VkDevice, image: v.VkImage, alloc: [*c]const v.VkAllocationCallbacks) callconv(.c) void {
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (&images) |*im| if (im.handle == image) {
            im.* = .{};
        };
    }
    const next: fnType("vkDestroyImage") = @ptrCast(gdpa.?(dev, "vkDestroyImage").?);
    next(dev, image, alloc);
}
fn rememberQueue(q: v.VkQueue, family: u32) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    for (&queues) |*x| if (x.handle == null or x.handle == q) {
        x.* = .{ .handle = q, .family = family };
        return;
    };
    disabled = true;
}
fn getQueue(dev: v.VkDevice, family: u32, index: u32, out: [*c]v.VkQueue) callconv(.c) void {
    const next: fnType("vkGetDeviceQueue") = @ptrCast(gdpa.?(dev, "vkGetDeviceQueue").?);
    next(dev, family, index, out);
    rememberQueue(out.*, family);
}
fn getQueue2(dev: v.VkDevice, info: [*c]const v.VkDeviceQueueInfo2, out: [*c]v.VkQueue) callconv(.c) void {
    const next: fnType("vkGetDeviceQueue2") = @ptrCast(gdpa.?(dev, "vkGetDeviceQueue2").?);
    next(dev, info, out);
    rememberQueue(out.*, info.*.queueFamilyIndex);
}
fn beginCommands(cb: v.VkCommandBuffer, info: [*c]const v.VkCommandBufferBeginInfo) callconv(.c) v.VkResult {
    const result = D("vkBeginCommandBuffer")(cb, info);
    if (result == v.VK_SUCCESS) {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        if (command(cb, true)) |c| {
            c.count = 0;
            c.overflow = false;
        } else disabled = true;
    }
    return result;
}
fn freeCommands(dev: v.VkDevice, pool: v.VkCommandPool, count: u32, list: [*c]const v.VkCommandBuffer) callconv(.c) void {
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        if (count > 0) for (list[0..count]) |cb| if (command(cb, false)) |c| {
            c.* = .{};
        };
    }
    const next: fnType("vkFreeCommandBuffers") = @ptrCast(gdpa.?(dev, "vkFreeCommandBuffers").?);
    next(dev, pool, count, list);
}
fn barrier(cb: v.VkCommandBuffer, src: v.VkPipelineStageFlags, dst: v.VkPipelineStageFlags, flags: v.VkDependencyFlags, nm: u32, mem: [*c]const v.VkMemoryBarrier, nb: u32, buf: [*c]const v.VkBufferMemoryBarrier, ni: u32, list: [*c]const v.VkImageMemoryBarrier) callconv(.c) void {
    D("vkCmdPipelineBarrier")(cb, src, dst, flags, nm, mem, nb, buf, ni, list);
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    const cmd = command(cb, false) orelse return;
    if (ni == 0) return;
    for (list[0..ni]) |b| for (images) |im| {
        if (im.handle == null or im.handle != b.image) continue;
        const change: Change = .{ .image = b.image, .layout = b.newLayout, .external_owner = b.dstQueueFamilyIndex == v.VK_QUEUE_FAMILY_EXTERNAL or b.dstQueueFamilyIndex == v.VK_QUEUE_FAMILY_FOREIGN_EXT };
        var found = false;
        for (cmd.changes[0..cmd.count]) |*x| if (x.image == b.image) {
            x.* = change;
            found = true;
            break;
        };
        if (!found) {
            if (cmd.count == max_images) {
                cmd.overflow = true;
            } else {
                cmd.changes[cmd.count] = change;
                cmd.count += 1;
            }
        }
    };
}
fn apply(cb: v.VkCommandBuffer, q: v.VkQueue) void {
    if (command(cb, false)) |cmd| {
        if (cmd.overflow) {
            disabled = true;
            return;
        }
        for (cmd.changes[0..cmd.count]) |change| for (&images) |*im| if (im.handle == change.image) {
            im.layout = change.layout;
            im.known = change.layout != v.VK_IMAGE_LAYOUT_UNDEFINED;
            im.last_queue = q;
            im.submission = submission_id;
            im.external_owner = change.external_owner;
        };
    }
}
fn submit(q: v.VkQueue, count: u32, list: [*c]const v.VkSubmitInfo, fence: v.VkFence) callconv(.c) v.VkResult {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    const result = D("vkQueueSubmit")(q, count, list, fence);
    if (result != v.VK_SUCCESS or count == 0) return result;
    submission_id += 1;
    for (list[0..count]) |s| {
        if (s.commandBufferCount > 0) for (s.pCommandBuffers[0..s.commandBufferCount]) |cb| apply(cb, q);
    }
    if (!disabled and count > 0) maybeCapture(q);
    return result;
}
fn check(result: v.VkResult) !void {
    if (result != v.VK_SUCCESS) {
        log("Vulkan failure {d}", .{result});
        return error.VulkanFailure;
    }
}
fn memoryType(bits: u32, flags: u32) !u32 {
    var props: v.VkPhysicalDeviceMemoryProperties = undefined;
    I("vkGetPhysicalDeviceMemoryProperties")(physical, &props);
    for (props.memoryTypes[0..props.memoryTypeCount], 0..) |t, i| if ((bits & (@as(u32, 1) << @intCast(i))) != 0 and (t.propertyFlags & flags) == flags) return @intCast(i);
    return error.NoHostMemory;
}
fn writeAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailure;
        offset += n;
    }
}
fn save(name: [*:0]const u8, bytes: []const u8) !void {
    const raw = linux.openat(directory, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(raw) != .SUCCESS) return error.OutputExistsOrUnavailable;
    const fd: i32 = @intCast(raw);
    defer _ = linux.close(fd);
    try writeAll(fd, bytes);
}
fn recordCopy(cb: v.VkCommandBuffer, im: Image, buffer: v.VkBuffer) !void {
    var begin = std.mem.zeroes(v.VkCommandBufferBeginInfo);
    begin.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = v.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try check(D("vkBeginCommandBuffer")(cb, &begin));
    var ib = std.mem.zeroes(v.VkImageMemoryBarrier);
    ib.sType = v.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    ib.srcAccessMask = v.VK_ACCESS_MEMORY_WRITE_BIT;
    ib.dstAccessMask = v.VK_ACCESS_TRANSFER_READ_BIT;
    ib.oldLayout = im.layout;
    ib.newLayout = v.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    ib.srcQueueFamilyIndex = v.VK_QUEUE_FAMILY_IGNORED;
    ib.dstQueueFamilyIndex = v.VK_QUEUE_FAMILY_IGNORED;
    ib.image = im.handle;
    ib.subresourceRange = .{ .aspectMask = v.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    D("vkCmdPipelineBarrier")(cb, v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, v.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &ib);
    var region = std.mem.zeroes(v.VkBufferImageCopy);
    region.imageSubresource = .{ .aspectMask = v.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    region.imageExtent = .{ .width = im.width, .height = im.height, .depth = 1 };
    D("vkCmdCopyImageToBuffer")(cb, im.handle, v.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    ib.srcAccessMask = v.VK_ACCESS_TRANSFER_READ_BIT;
    ib.dstAccessMask = v.VK_ACCESS_MEMORY_READ_BIT | v.VK_ACCESS_MEMORY_WRITE_BIT;
    ib.oldLayout = v.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    ib.newLayout = im.layout;
    var mb = std.mem.zeroes(v.VkMemoryBarrier);
    mb.sType = v.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    mb.srcAccessMask = v.VK_ACCESS_TRANSFER_WRITE_BIT;
    mb.dstAccessMask = v.VK_ACCESS_HOST_READ_BIT;
    D("vkCmdPipelineBarrier")(cb, v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | v.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, null, 1, &ib);
    try check(D("vkEndCommandBuffer")(cb));
}
fn readImage(q: v.VkQueue, family: u32, im: Image, label: []const u8, index: usize) !void {
    // Only explicitly observed, still-owned layouts are eligible. Unknown render-pass
    // implicit transitions / external ownership are not guessed into validity.
    if (!im.known or im.external_owner or im.layout == v.VK_IMAGE_LAYOUT_UNDEFINED or im.layout == v.VK_IMAGE_LAYOUT_PREINITIALIZED) return error.UnknownLayoutOrOwnership;
    const size: u64 = @as(u64, im.width) * im.height * 4;
    var buffer: v.VkBuffer = null;
    var memory: v.VkDeviceMemory = null;
    var pool: v.VkCommandPool = null;
    var fence: v.VkFence = null;
    var pending = false;
    // On timeout retain bounded GPU objects until process teardown rather than freeing
    // resources still referenced by the submitted command buffer.
    defer if (!pending) {
        if (fence != null) D("vkDestroyFence")(device, fence, null);
        if (pool != null) D("vkDestroyCommandPool")(device, pool, null);
        if (buffer != null) D("vkDestroyBuffer")(device, buffer, null);
        if (memory != null) D("vkFreeMemory")(device, memory, null);
    };
    var bci = std.mem.zeroes(v.VkBufferCreateInfo);
    bci.sType = v.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = size;
    bci.usage = v.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = v.VK_SHARING_MODE_EXCLUSIVE;
    try check(D("vkCreateBuffer")(device, &bci, null, &buffer));
    var req: v.VkMemoryRequirements = undefined;
    D("vkGetBufferMemoryRequirements")(device, buffer, &req);
    var mai = std.mem.zeroes(v.VkMemoryAllocateInfo);
    mai.sType = v.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = try memoryType(req.memoryTypeBits, v.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | v.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    try check(D("vkAllocateMemory")(device, &mai, null, &memory));
    try check(D("vkBindBufferMemory")(device, buffer, memory, 0));
    var pci = std.mem.zeroes(v.VkCommandPoolCreateInfo);
    pci.sType = v.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex = family;
    try check(D("vkCreateCommandPool")(device, &pci, null, &pool));
    var cb: v.VkCommandBuffer = null;
    var cai = std.mem.zeroes(v.VkCommandBufferAllocateInfo);
    cai.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cai.commandPool = pool;
    cai.commandBufferCount = 1;
    cai.level = v.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    try check(D("vkAllocateCommandBuffers")(device, &cai, &cb));
    try recordCopy(cb, im, buffer);
    var fci = std.mem.zeroes(v.VkFenceCreateInfo);
    fci.sType = v.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    try check(D("vkCreateFence")(device, &fci, null, &fence));
    var si = std.mem.zeroes(v.VkSubmitInfo);
    si.sType = v.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    try check(D("vkQueueSubmit")(q, 1, &si, fence));
    pending = true;
    try check(D("vkWaitForFences")(device, 1, &fence, v.VK_TRUE, 2_000_000_000));
    pending = false;
    var mapped: ?*anyopaque = null;
    try check(D("vkMapMemory")(device, memory, 0, size, 0, &mapped));
    defer D("vkUnmapMemory")(device, memory);
    const pixels: [*]const u8 = @ptrCast(mapped.?);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ im.width, im.height });
    const ppm = try a.alloc(u8, header.len + im.width * im.height * 3);
    @memcpy(ppm[0..header.len], header);
    const bgra = im.format == 44 or im.format == 50;
    for (0..im.width * im.height) |i| {
        ppm[header.len + i * 3] = pixels[i * 4 + @as(usize, if (bgra) 2 else 0)];
        ppm[header.len + i * 3 + 1] = pixels[i * 4 + 1];
        ppm[header.len + i * 3 + 2] = pixels[i * 4 + @as(usize, if (bgra) 0 else 2)];
    }
    const name = try std.fmt.allocPrintSentinel(a, "{s}-{d}.ppm", .{ label, index }, 0);
    try save(name, ppm);
    log("saved {s}, image={x}, inode={d}, layout={d}", .{ name, @intFromPtr(im.handle), im.inode, im.layout });
}
fn maybeCapture(q: v.VkQueue) void {
    if (!dir()) return;
    tickStream(q);
    const raw = linux.openat(directory, "request", .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(raw) != .SUCCESS) return;
    const fd: i32 = @intCast(raw);
    defer _ = linux.close(fd);
    var label: [40:0]u8 = @splat(0);
    const n = linux.read(fd, &label, label.len);
    _ = linux.unlinkat(directory, "request", 0);
    if (linux.errno(n) != .SUCCESS or n == 0 or n > 32) return;
    for (label[0..n]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return;
    label[n] = 0;
    var family: ?u32 = null;
    for (queues) |x| if (x.handle == q) {
        family = x.family;
        break;
    };
    const Captured = struct { index: usize, inode: u64, format: u32, layout: v.VkImageLayout };
    var details: [max_images]Captured = undefined;
    var captured: usize = 0;
    var skipped: usize = 0;
    var failures: usize = 0;
    if (family) |f| for (images, 0..) |im, i| {
        if (im.handle == null or im.last_queue != q or im.inode == 0 or im.submission != submission_id) continue;
        readImage(q, f, im, label[0..n], i) catch |err| {
            if (err == error.UnknownLayoutOrOwnership) {
                log("skip image={d} known={} external={} layout={d}", .{ i, im.known, im.external_owner, im.layout });
                skipped += 1;
            } else {
                failures += 1;
                disabled = true;
                log("capture failed: {s}", .{@errorName(err)});
                break;
            }
            continue;
        };
        details[captured] = .{ .index = i, .inode = im.inode, .format = im.format, .layout = im.layout };
        captured += 1;
    };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const data = std.json.Stringify.valueAlloc(arena.allocator(), .{ .captured = captured, .skipped = skipped, .failures = failures, .disabled = disabled, .width = 960, .height = 960, .images = details[0..captured] }, .{}) catch return;
    var name: [80:0]u8 = @splat(0);
    const path = std.fmt.bufPrintZ(&name, "{s}.complete", .{label[0..n]}) catch return;
    save(path, data) catch {};
}

fn markMemory(image: v.VkImage, memory: v.VkDeviceMemory) void {
    for (&images) |*im| if (im.handle == image) {
        im.memory = memory;
    };
}
fn bindImage(dev: v.VkDevice, image: v.VkImage, memory: v.VkDeviceMemory, offset: v.VkDeviceSize) callconv(.c) v.VkResult {
    const next: fnType("vkBindImageMemory") = @ptrCast(gdpa.?(dev, "vkBindImageMemory").?);
    const result = next(dev, image, memory, offset);
    if (result == v.VK_SUCCESS) {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        markMemory(image, memory);
    }
    return result;
}
fn bindImage2(dev: v.VkDevice, count: u32, binds: [*c]const v.VkBindImageMemoryInfo) callconv(.c) v.VkResult {
    const next: fnType("vkBindImageMemory2") = @ptrCast(gdpa.?(dev, "vkBindImageMemory2").?);
    const result = next(dev, count, binds);
    if (result == v.VK_SUCCESS) {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        if (count > 0) for (binds[0..count]) |b| markMemory(b.image, b.memory);
    }
    return result;
}
fn memoryFd(dev: v.VkDevice, info: [*c]const v.VkMemoryGetFdInfoKHR, fd: [*c]i32) callconv(.c) v.VkResult {
    const next: fnType("vkGetMemoryFdKHR") = @ptrCast(gdpa.?(dev, "vkGetMemoryFdKHR").?);
    const result = next(dev, info, fd);
    if (result == v.VK_SUCCESS) {
        var stat: linux.Statx = undefined;
        if (linux.errno(linux.statx(fd.*, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stat)) == .SUCCESS and stat.mask.INO) {
            std.Io.Threaded.mutexLock(&mutex);
            defer std.Io.Threaded.mutexUnlock(&mutex);
            for (&images, 0..) |*im, i| if (im.memory == info.*.memory) {
                im.inode = stat.ino;
                log("exported image={d} inode={d}", .{ i, stat.ino });
            };
        }
    }
    return result;
}
fn endRenderPass(cb: v.VkCommandBuffer) callconv(.c) void {
    D("vkCmdEndRenderPass")(cb);
    passEnd(cb);
}

fn fakeGdpa(_: v.VkDevice, name: [*c]const u8) callconv(.c) v.PFN_vkVoidFunction {
    if (std.mem.eql(u8, std.mem.span(name), "vkCmdPipelineBarrier")) return @ptrCast(&fakeBarrier);
    if (std.mem.eql(u8, std.mem.span(name), "vkQueueSubmit")) return @ptrCast(&fakeSubmit);
    return null;
}
fn fakeBarrier(_: v.VkCommandBuffer, _: u32, _: u32, _: u32, _: u32, _: [*c]const v.VkMemoryBarrier, _: u32, _: [*c]const v.VkBufferMemoryBarrier, _: u32, _: [*c]const v.VkImageMemoryBarrier) callconv(.c) void {}
fn fakeSubmit(_: v.VkQueue, _: u32, _: [*c]const v.VkSubmitInfo, _: v.VkFence) callconv(.c) v.VkResult {
    return v.VK_SUCCESS;
}
test "valid zero-count Vulkan calls accept null pointers" {
    gdpa = fakeGdpa;
    defer gdpa = null;
    try std.testing.expect(vkGetDeviceProcAddr(null, "vkQueueSubmit2") == null);
    try std.testing.expect(vkGetDeviceProcAddr(null, "vkQueueSubmit") != null);
    const cb: v.VkCommandBuffer = @ptrFromInt(16);
    _ = command(cb, true);
    defer {
        if (command(cb, false)) |cmd| cmd.* = .{};
    }
    barrier(cb, 0, 0, 0, 0, null, 0, null, 0, null);
    try std.testing.expectEqual(@as(v.VkResult, v.VK_SUCCESS), submit(null, 0, null, null));
    var s = std.mem.zeroes(v.VkSubmitInfo);
    try std.testing.expectEqual(@as(v.VkResult, v.VK_SUCCESS), submit(null, 1, &s, null));
}

fn remember2(cb: v.VkCommandBuffer, info: [*c]const v.VkDependencyInfoKHR) void {
    if (info.*.imageMemoryBarrierCount == 0) return;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    const cmd = command(cb, false) orelse return;
    for (info.*.pImageMemoryBarriers[0..info.*.imageMemoryBarrierCount]) |b| for (images) |im| {
        if (im.handle == null or im.handle != b.image) continue;
        const change: Change = .{ .image = b.image, .layout = b.newLayout, .external_owner = b.dstQueueFamilyIndex == v.VK_QUEUE_FAMILY_EXTERNAL or b.dstQueueFamilyIndex == v.VK_QUEUE_FAMILY_FOREIGN_EXT };
        var found = false;
        for (cmd.changes[0..cmd.count]) |*x| if (x.image == b.image) {
            x.* = change;
            found = true;
            break;
        };
        if (!found) {
            if (cmd.count == max_images) {
                cmd.overflow = true;
            } else {
                cmd.changes[cmd.count] = change;
                cmd.count += 1;
            }
        }
    };
}
fn barrier2(cb: v.VkCommandBuffer, info: [*c]const v.VkDependencyInfoKHR) callconv(.c) void {
    const next: fnType("vkCmdPipelineBarrier2KHR") = @ptrCast(gdpa.?(device, "vkCmdPipelineBarrier2").?);
    next(cb, info);
    remember2(cb, info);
}
fn barrier2Khr(cb: v.VkCommandBuffer, info: [*c]const v.VkDependencyInfoKHR) callconv(.c) void {
    D("vkCmdPipelineBarrier2KHR")(cb, info);
    remember2(cb, info);
}
fn afterSubmit2(q: v.VkQueue, count: u32, list: [*c]const v.VkSubmitInfo2KHR) void {
    if (count == 0) return;
    submission_id += 1;
    for (list[0..count]) |s| if (s.commandBufferInfoCount > 0) {
        for (s.pCommandBufferInfos[0..s.commandBufferInfoCount]) |cb| apply(cb.commandBuffer, q);
    };
    if (!disabled) maybeCapture(q);
}
fn submit2(q: v.VkQueue, count: u32, list: [*c]const v.VkSubmitInfo2KHR, fence: v.VkFence) callconv(.c) v.VkResult {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    const next: fnType("vkQueueSubmit2KHR") = @ptrCast(gdpa.?(device, "vkQueueSubmit2").?);
    const result = next(q, count, list, fence);
    if (result == v.VK_SUCCESS) afterSubmit2(q, count, list);
    return result;
}
fn submit2Khr(q: v.VkQueue, count: u32, list: [*c]const v.VkSubmitInfo2KHR, fence: v.VkFence) callconv(.c) v.VkResult {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    const result = D("vkQueueSubmit2KHR")(q, count, list, fence);
    if (result == v.VK_SUCCESS) afterSubmit2(q, count, list);
    return result;
}

const Pass = struct { handle: v.VkRenderPass = null, count: u32 = 0, finals: [16]v.VkImageLayout = @splat(v.VK_IMAGE_LAYOUT_UNDEFINED) };
const Framebuffer = struct { handle: v.VkFramebuffer = null, count: u32 = 0, views: [16]v.VkImageView = @splat(null) };
const View = struct { handle: v.VkImageView = null, image: v.VkImage = null };
var passes: [128]Pass = @splat(.{});
var framebuffers: [256]Framebuffer = @splat(.{});
var views: [512]View = @splat(.{});
fn changeImage(cmd: *Commands, image: v.VkImage, layout: v.VkImageLayout) void {
    for (cmd.changes[0..cmd.count]) |*change| if (change.image == image) {
        change.layout = layout;
        change.external_owner = false;
        return;
    };
    if (cmd.count == max_images) {
        cmd.overflow = true;
        return;
    }
    cmd.changes[cmd.count] = .{ .image = image, .layout = layout, .external_owner = false };
    cmd.count += 1;
}
fn passBegin(cb: v.VkCommandBuffer, info: [*c]const v.VkRenderPassBeginInfo) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (command(cb, false)) |cmd| {
        cmd.pass = info.*.renderPass;
        cmd.framebuffer = info.*.framebuffer;
    }
}
fn passEnd(cb: v.VkCommandBuffer) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    const cmd = command(cb, false) orelse return;
    defer {
        cmd.pass = null;
        cmd.framebuffer = null;
    }
    var pass: ?Pass = null;
    var fb: ?Framebuffer = null;
    for (passes) |p| if (p.handle != null and p.handle == cmd.pass) {
        pass = p;
        break;
    };
    for (framebuffers) |f| if (f.handle != null and f.handle == cmd.framebuffer) {
        fb = f;
        break;
    };
    if (pass == null or fb == null or pass.?.count != fb.?.count) {
        for (images) |im| if (im.handle != null) {
            changeImage(cmd, im.handle, v.VK_IMAGE_LAYOUT_UNDEFINED);
        };
        return;
    }
    for (fb.?.views[0..fb.?.count], 0..) |view, i| for (views) |vi| {
        if (vi.handle == null or vi.handle != view) continue;
        for (images) |im| if (im.handle != null and im.handle == vi.image) {
            changeImage(cmd, im.handle, pass.?.finals[i]);
        };
    };
}
fn createView(dev: v.VkDevice, ci: [*c]const v.VkImageViewCreateInfo, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkImageView) callconv(.c) v.VkResult {
    const next: fnType("vkCreateImageView") = @ptrCast(gdpa.?(dev, "vkCreateImageView").?);
    const r = next(dev, ci, alloc, out);
    if (r == v.VK_SUCCESS) {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (images) |im| if (im.handle != null and im.handle == ci.*.image) {
            for (&views) |*vi| if (vi.handle == null) {
                vi.* = .{ .handle = out.*, .image = ci.*.image };
                return r;
            };
            disabled = true;
        };
    }
    return r;
}
fn destroyView(dev: v.VkDevice, view: v.VkImageView, alloc: [*c]const v.VkAllocationCallbacks) callconv(.c) void {
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (&views) |*vi| if (vi.handle == view) {
            vi.* = .{};
        };
    }
    const next: fnType("vkDestroyImageView") = @ptrCast(gdpa.?(dev, "vkDestroyImageView").?);
    next(dev, view, alloc);
}
fn createPass(dev: v.VkDevice, ci: [*c]const v.VkRenderPassCreateInfo, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkRenderPass) callconv(.c) v.VkResult {
    const next: fnType("vkCreateRenderPass") = @ptrCast(gdpa.?(dev, "vkCreateRenderPass").?);
    const r = next(dev, ci, alloc, out);
    if (r == v.VK_SUCCESS and ci.*.attachmentCount <= 16) {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (&passes) |*p| if (p.handle == null) {
            p.* = .{ .handle = out.*, .count = ci.*.attachmentCount };
            if (p.count > 0) for (ci.*.pAttachments[0..p.count], 0..) |a, i| {
                p.finals[i] = a.finalLayout;
            };
            return r;
        };
        disabled = true;
    }
    return r;
}
fn rememberPass2(ci: [*c]const v.VkRenderPassCreateInfo2, handle: v.VkRenderPass) void {
    if (ci.*.attachmentCount > 16) return;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    for (&passes) |*p| if (p.handle == null) {
        p.* = .{ .handle = handle, .count = ci.*.attachmentCount };
        if (p.count > 0) for (ci.*.pAttachments[0..p.count], 0..) |a, i| {
            p.finals[i] = a.finalLayout;
        };
        return;
    };
    disabled = true;
}
fn createPass2(dev: v.VkDevice, ci: [*c]const v.VkRenderPassCreateInfo2, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkRenderPass) callconv(.c) v.VkResult {
    const next: fnType("vkCreateRenderPass2") = @ptrCast(gdpa.?(dev, "vkCreateRenderPass2").?);
    const r = next(dev, ci, alloc, out);
    if (r == v.VK_SUCCESS) rememberPass2(ci, out.*);
    return r;
}
fn createPass2Khr(dev: v.VkDevice, ci: [*c]const v.VkRenderPassCreateInfo2, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkRenderPass) callconv(.c) v.VkResult {
    const next: fnType("vkCreateRenderPass2KHR") = @ptrCast(gdpa.?(dev, "vkCreateRenderPass2KHR").?);
    const r = next(dev, ci, alloc, out);
    if (r == v.VK_SUCCESS) rememberPass2(ci, out.*);
    return r;
}
fn destroyPass(dev: v.VkDevice, handle: v.VkRenderPass, alloc: [*c]const v.VkAllocationCallbacks) callconv(.c) void {
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (&passes) |*p| if (p.handle == handle) {
            p.* = .{};
        };
    }
    const next: fnType("vkDestroyRenderPass") = @ptrCast(gdpa.?(dev, "vkDestroyRenderPass").?);
    next(dev, handle, alloc);
}
fn createFramebuffer(dev: v.VkDevice, ci: [*c]const v.VkFramebufferCreateInfo, alloc: [*c]const v.VkAllocationCallbacks, out: [*c]v.VkFramebuffer) callconv(.c) v.VkResult {
    const next: fnType("vkCreateFramebuffer") = @ptrCast(gdpa.?(dev, "vkCreateFramebuffer").?);
    const r = next(dev, ci, alloc, out);
    if (r == v.VK_SUCCESS and ci.*.attachmentCount <= 16 and (ci.*.flags & v.VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT) == 0) {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (&framebuffers) |*f| if (f.handle == null) {
            f.* = .{ .handle = out.*, .count = ci.*.attachmentCount };
            if (f.count > 0) @memcpy(f.views[0..f.count], ci.*.pAttachments[0..f.count]);
            return r;
        };
        disabled = true;
    }
    return r;
}
fn destroyFramebuffer(dev: v.VkDevice, handle: v.VkFramebuffer, alloc: [*c]const v.VkAllocationCallbacks) callconv(.c) void {
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        for (&framebuffers) |*f| if (f.handle == handle) {
            f.* = .{};
        };
    }
    const next: fnType("vkDestroyFramebuffer") = @ptrCast(gdpa.?(dev, "vkDestroyFramebuffer").?);
    next(dev, handle, alloc);
}
fn beginPass(cb: v.VkCommandBuffer, info: [*c]const v.VkRenderPassBeginInfo, contents: v.VkSubpassContents) callconv(.c) void {
    D("vkCmdBeginRenderPass")(cb, info, contents);
    passBegin(cb, info);
}
fn beginPass2(cb: v.VkCommandBuffer, info: [*c]const v.VkRenderPassBeginInfo, sub: [*c]const v.VkSubpassBeginInfo) callconv(.c) void {
    D("vkCmdBeginRenderPass2")(cb, info, sub);
    passBegin(cb, info);
}
fn beginPass2Khr(cb: v.VkCommandBuffer, info: [*c]const v.VkRenderPassBeginInfo, sub: [*c]const v.VkSubpassBeginInfo) callconv(.c) void {
    D("vkCmdBeginRenderPass2KHR")(cb, info, sub);
    passBegin(cb, info);
}
fn endPass2(cb: v.VkCommandBuffer, info: [*c]const v.VkSubpassEndInfo) callconv(.c) void {
    D("vkCmdEndRenderPass2")(cb, info);
    passEnd(cb);
}
fn endPass2Khr(cb: v.VkCommandBuffer, info: [*c]const v.VkSubpassEndInfo) callconv(.c) void {
    D("vkCmdEndRenderPass2KHR")(cb, info);
    passEnd(cb);
}

fn unsupportedPath() void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!disabled) log("capture disabled: secondary command buffers or dynamic rendering need additional tracking", .{});
    disabled = true;
}
fn executeCommands(cb: v.VkCommandBuffer, count: u32, secondary: [*c]const v.VkCommandBuffer) callconv(.c) void {
    D("vkCmdExecuteCommands")(cb, count, secondary);
    if (count > 0) unsupportedPath();
}
fn beginRendering(cb: v.VkCommandBuffer, info: [*c]const v.VkRenderingInfoKHR) callconv(.c) void {
    const next: fnType("vkCmdBeginRenderingKHR") = @ptrCast(gdpa.?(device, "vkCmdBeginRendering").?);
    next(cb, info);
    unsupportedPath();
}
fn beginRenderingKhr(cb: v.VkCommandBuffer, info: [*c]const v.VkRenderingInfoKHR) callconv(.c) void {
    D("vkCmdBeginRenderingKHR")(cb, info);
    unsupportedPath();
}
test "render-pass final layouts apply only to their framebuffer images" {
    const cb: v.VkCommandBuffer = @ptrFromInt(16);
    const pass: v.VkRenderPass = @ptrFromInt(32);
    const fb: v.VkFramebuffer = @ptrFromInt(48);
    const view: v.VkImageView = @ptrFromInt(64);
    const image: v.VkImage = @ptrFromInt(80);
    images[0] = .{ .handle = image };
    images[1] = .{ .handle = @ptrFromInt(96), .known = true, .layout = v.VK_IMAGE_LAYOUT_GENERAL };
    passes[0] = .{ .handle = pass, .count = 1 };
    passes[0].finals[0] = v.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    framebuffers[0] = .{ .handle = fb, .count = 1 };
    framebuffers[0].views[0] = view;
    views[0] = .{ .handle = view, .image = image };
    const cmd = command(cb, true).?;
    cmd.pass = pass;
    cmd.framebuffer = fb;
    defer {
        images[0] = .{};
        images[1] = .{};
        passes[0] = .{};
        framebuffers[0] = .{};
        views[0] = .{};
        cmd.* = .{};
    }
    passEnd(cb);
    apply(cb, null);
    try std.testing.expect(images[0].known);
    try std.testing.expectEqual(@as(v.VkImageLayout, v.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL), images[0].layout);
    try std.testing.expect(images[1].known);
    try std.testing.expectEqual(@as(v.VkImageLayout, v.VK_IMAGE_LAYOUT_GENERAL), images[1].layout);
}

// Eight per-image slots = four stereo frames. All Vulkan work stays on the
// submission thread; the CPU worker sees a slot only after its fence signals.
const Slot = struct {
    state: std.atomic.Value(u8) = .init(0), // 0 free, 1 GPU pending, 2 CPU ready
    buffer: v.VkBuffer = null,
    memory: v.VkDeviceMemory = null,
    pool: v.VkCommandPool = null,
    cb: v.VkCommandBuffer = null,
    fence: v.VkFence = null,
    pixels: ?*anyopaque = null,
    im: Image = .{},
    index: usize = 0,
    submission: u64 = 0,
    submitted_ns: u64 = 0,
    completed_ns: u64 = 0,
};
var slots: [8]Slot = @splat(.{});
var stream_thread: ?std.Thread = null;
var stream_stop: std.atomic.Value(bool) = .init(false);
var stream_write_failed: std.atomic.Value(bool) = .init(false);
var stream_fd: i32 = -1;
var stream_label: [33:0]u8 = @splat(0);
var stream_remaining: u32 = 0;
var stream_attempts: u32 = 0;
var stream_copied: u32 = 0;
var stream_dropped: u32 = 0;
var stream_finished = false;
var stream_queue_family: ?u32 = null;
fn monotonicNs() u64 {
    var t: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &t)) != .SUCCESS) return 0;
    return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
}
const Marker = struct { count: u64 = 0, sum_x: u64 = 0, sum_y: u64 = 0 };
fn markerPixels(pixels: [*]const u8, width: usize, height: usize, bgra: bool) Marker {
    var result: Marker = .{};
    for (0..height) |y| for (0..width) |x| {
        const i = (y * width + x) * 4;
        if (pixels[i + @as(usize, if (bgra) 2 else 0)] > 200 and pixels[i + 1] < 20 and pixels[i + @as(usize, if (bgra) 0 else 2)] < 20) {
            result.count += 1;
            result.sum_x += x;
            result.sum_y += y;
        }
    };
    return result;
}
const FrameId = struct { valid: bool = false, generation: u16 = 0, matching_rows: u32 = 0, conflicting_rows: u32 = 0, first_x: usize = 0 };
// Find forty separate dominant green/blue cells in the known head-fixed upper
// stripe. Decode by run order, not assumed eye offset or exact sample pixels.
fn imageFrameId(pixels: [*]const u8, width: usize, height: usize, bgra: bool) FrameId {
    var result: FrameId = .{};
    if (width != 960 or height != 960) return result;
    for (340..410) |y| {
        var cells: [40]u1 = undefined;
        var count: usize = 0;
        var run: usize = 0;
        var color: u1 = 0;
        var bad = false;
        var first_x: usize = 0;
        for (80..880) |x| {
            const i = (y * width + x) * 4;
            const r = pixels[i + @as(usize, if (bgra) 2 else 0)];
            const g = pixels[i + 1];
            const b = pixels[i + @as(usize, if (bgra) 0 else 2)];
            const active = r < 40 and ((g > 180 and b < 40) or (b > 180 and g < 40));
            if (active) {
                const next: u1 = if (b > g) 1 else 0;
                if (run > 0 and color != next) bad = true;
                color = next;
                if (count == 0 and run == 0) first_x = x;
                run += 1;
            } else if (run > 0) {
                if (run < 5 or run > 20 or count == cells.len) {
                    bad = true;
                    break;
                }
                cells[count] = color;
                count += 1;
                run = 0;
            }
        }
        if (bad or run > 0 or count != 40) continue;
        if (!std.mem.eql(u1, cells[0..4], &.{ 0, 0, 1, 0 }) or !std.mem.eql(u1, cells[36..40], &.{ 1, 1, 0, 1 })) continue;
        var generation: u16 = 0;
        for (0..16) |bit| {
            if (cells[bit + 4] == cells[bit + 20]) {
                bad = true;
                break;
            }
            generation |= @as(u16, cells[bit + 4]) << @intCast(bit);
        }
        if (bad) continue;
        if (result.matching_rows == 0) {
            result.generation = generation;
            result.first_x = first_x;
            result.matching_rows = 1;
        } else if (generation == result.generation) {
            result.matching_rows += 1;
        } else result.conflicting_rows += 1;
    }
    result.valid = result.matching_rows >= 3 and result.conflicting_rows == 0;
    return result;
}
test "frame ID rejects incomplete, noncomplementary, and conflicting stripes" {
    const pixels = try std.testing.allocator.alloc(u8, 960 * 960 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    try std.testing.expect(!imageFrameId(pixels.ptr, 960, 960, false).valid);
    for (0..40) |cell| {
        const generation: u16 = 0xa53c;
        const color: u1 = if (cell < 4) ([_]u1{ 0, 0, 1, 0 })[cell] else if (cell >= 36) ([_]u1{ 1, 1, 0, 1 })[cell - 36] else @intCast(((generation >> @as(u4, @intCast((cell - 4) % 16))) & 1) ^ @as(u16, if (cell >= 20) 1 else 0));
        for (370..376) |y| for (0..10) |dx| {
            pixels[(y * 960 + 140 + cell * 17 + dx) * 4 + @as(usize, if (color == 1) 2 else 1)] = 255;
        };
    }
    const decoded = imageFrameId(pixels.ptr, 960, 960, false);
    try std.testing.expect(decoded.valid);
    try std.testing.expectEqual(@as(u16, 0xa53c), decoded.generation);
    // A fully valid, different ID on one row must invalidate the whole strip.
    for ([_]usize{ 4, 20 }) |cell| for (0..10) |dx| {
        const i = (370 * 960 + 140 + cell * 17 + dx) * 4;
        const old = pixels[i + 1];
        pixels[i + 1] = pixels[i + 2];
        pixels[i + 2] = old;
    };
    const conflict = imageFrameId(pixels.ptr, 960, 960, false);
    try std.testing.expect(!conflict.valid and conflict.conflicting_rows > 0);
    for ([_]usize{ 4, 20 }) |cell| for (0..10) |dx| {
        const i = (370 * 960 + 140 + cell * 17 + dx) * 4;
        const old = pixels[i + 1];
        pixels[i + 1] = pixels[i + 2];
        pixels[i + 2] = old;
    };
    // Same image in BGRA channel order must decode to the same generation.
    for (0..960 * 960) |i| {
        const old = pixels[i * 4];
        pixels[i * 4] = pixels[i * 4 + 2];
        pixels[i * 4 + 2] = old;
    }
    const bgra = imageFrameId(pixels.ptr, 960, 960, true);
    try std.testing.expect(bgra.valid and bgra.generation == decoded.generation);
    for (0..960 * 960) |i| {
        const old = pixels[i * 4];
        pixels[i * 4] = pixels[i * 4 + 2];
        pixels[i * 4 + 2] = old;
    }
    // Corrupt one complementary cell on every scan line.
    for (370..376) |y| for (0..10) |dx| {
        const i = (y * 960 + 140 + 20 * 17 + dx) * 4;
        const old = pixels[i + 1];
        pixels[i + 1] = pixels[i + 2];
        pixels[i + 2] = old;
    };
    try std.testing.expect(!imageFrameId(pixels.ptr, 960, 960, false).valid);
}

fn wristPixels(pixels: [*]const u8, width: usize, height: usize) Marker {
    var result: Marker = .{};
    // Magenta is symmetric under RGBA/BGRA, and unique to the opt-in wrist marker.
    for (height * 2 / 3..height) |y| for (0..width) |x| {
        const i = (y * width + x) * 4;
        if (pixels[i] > 200 and pixels[i + 1] < 40 and pixels[i + 2] > 200) {
            result.count += 1;
            result.sum_x += x;
            result.sum_y += y;
        }
    };
    return result;
}
fn streamWorker() void {
    while (!stream_stop.load(.acquire)) {
        var worked = false;
        for (&slots) |*slot| {
            if (slot.state.load(.acquire) != 2) continue;
            worked = true;
            const begin = monotonicNs();
            const m = markerPixels(@ptrCast(slot.pixels.?), slot.im.width, slot.im.height, slot.im.format == 44 or slot.im.format == 50);
            const wrist = wristPixels(@ptrCast(slot.pixels.?), slot.im.width, slot.im.height);
            const identity = imageFrameId(@ptrCast(slot.pixels.?), slot.im.width, slot.im.height, slot.im.format == 44 or slot.im.format == 50);
            var b: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&b, "{{\"submission\":{d},\"index\":{d},\"inode\":{d},\"submittedNs\":{d},\"completedNs\":{d},\"analyzeBeginNs\":{d},\"analyzeEndNs\":{d},\"count\":{d},\"sumX\":{d},\"sumY\":{d},\"frameIdValid\":{},\"frameId\":{d},\"idRows\":{d},\"idFirstX\":{d},\"idConflicts\":{d},\"wristCount\":{d},\"wristSumX\":{d},\"wristSumY\":{d}}}\n", .{ slot.submission, slot.index, slot.im.inode, slot.submitted_ns, slot.completed_ns, begin, monotonicNs(), m.count, m.sum_x, m.sum_y, identity.valid, identity.generation, identity.matching_rows, identity.first_x, identity.conflicting_rows, wrist.count, wrist.sum_x, wrist.sum_y }) catch unreachable;
            writeAll(stream_fd, line) catch stream_write_failed.store(true, .release);
            slot.state.store(0, .release);
        }
        if (!worked) {
            const delay: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = linux.nanosleep(&delay, null);
        }
    }
}
fn allocateSlot(slot: *Slot, family: u32, im: Image) !void {
    const size = @as(u64, im.width) * im.height * 4;
    var ci = std.mem.zeroes(v.VkBufferCreateInfo);
    ci.sType = v.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    ci.size = size;
    ci.usage = v.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    try check(D("vkCreateBuffer")(device, &ci, null, &slot.buffer));
    var req: v.VkMemoryRequirements = undefined;
    D("vkGetBufferMemoryRequirements")(device, slot.buffer, &req);
    var mai = std.mem.zeroes(v.VkMemoryAllocateInfo);
    mai.sType = v.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = try memoryType(req.memoryTypeBits, v.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | v.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | v.VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
    try check(D("vkAllocateMemory")(device, &mai, null, &slot.memory));
    try check(D("vkBindBufferMemory")(device, slot.buffer, slot.memory, 0));
    try check(D("vkMapMemory")(device, slot.memory, 0, size, 0, &slot.pixels));
    var pci = std.mem.zeroes(v.VkCommandPoolCreateInfo);
    pci.sType = v.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.flags = v.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = family;
    try check(D("vkCreateCommandPool")(device, &pci, null, &slot.pool));
    var cai = std.mem.zeroes(v.VkCommandBufferAllocateInfo);
    cai.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cai.commandPool = slot.pool;
    cai.commandBufferCount = 1;
    cai.level = v.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    try check(D("vkAllocateCommandBuffers")(device, &cai, &slot.cb));
    var fci = std.mem.zeroes(v.VkFenceCreateInfo);
    fci.sType = v.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    try check(D("vkCreateFence")(device, &fci, null, &slot.fence));
}
fn startStream(q: v.VkQueue) !void {
    if (stream_fd >= 0 and !stream_finished) return; // A new request is accepted only after every slot drains.
    var first: ?Image = null;
    for (images) |im| if (im.handle != null and im.inode != 0 and im.last_queue == q and im.submission == submission_id and im.known and !im.external_owner) {
        first = im;
        break;
    };
    // A request must arrive at an actual final-eye submission.
    const im = first orelse return;
    const raw = linux.openat(directory, "stream", .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(raw) != .SUCCESS) return;
    const fd: i32 = @intCast(raw);
    defer _ = linux.close(fd);
    const n = linux.read(fd, &stream_label, stream_label.len);
    _ = linux.unlinkat(directory, "stream", 0);
    if (linux.errno(n) != .SUCCESS or n == 0 or n > 32) return error.InvalidStreamLabel;
    for (stream_label[0..n]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidStreamLabel;
    stream_label[n] = 0;
    var family: ?u32 = null;
    for (queues) |entry| if (entry.handle == q) {
        family = entry.family;
        break;
    };
    const f = family orelse return error.UnknownQueue;
    if (stream_queue_family) |previous| if (previous != f) return error.StreamQueueFamilyChanged;
    var name: [80:0]u8 = @splat(0);
    const path = try std.fmt.bufPrintZ(&name, "{s}.ndjson", .{stream_label[0..n]});
    const output = linux.openat(directory, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(output) != .SUCCESS) return error.OutputExistsOrUnavailable;
    if (stream_fd >= 0) _ = linux.close(stream_fd);
    stream_fd = @intCast(output);
    for (&slots) |*slot| if (slot.buffer == null) {
        try allocateSlot(slot, f, im);
    };
    stream_attempts = 0;
    stream_copied = 0;
    stream_dropped = 0;
    stream_finished = false;
    stream_write_failed.store(false, .release);
    stream_queue_family = f;
    stream_remaining = 450;
    if (stream_thread == null) stream_thread = try std.Thread.spawn(.{}, streamWorker, .{});
    log("asynchronous stream started, eight slots, 450 eligible submissions", .{});
}
fn tickStream(q: v.VkQueue) void {
    // Nonblocking fence checks only. A CPU-busy or GPU-busy slot is never reused.
    for (&slots) |*slot| if (slot.state.load(.acquire) == 1) {
        const status = D("vkGetFenceStatus")(device, slot.fence);
        if (status == v.VK_SUCCESS) {
            slot.completed_ns = monotonicNs();
            slot.state.store(2, .release);
        } else if (status != v.VK_NOT_READY) {
            disabled = true;
            return;
        }
    };
    if (stream_fd < 0 or stream_finished) startStream(q) catch |err| {
        log("stream start failed: {s}", .{@errorName(err)});
        disabled = true;
    };
    if (stream_remaining == 0) {
        if (stream_fd < 0 or stream_finished) return;
        for (&slots) |*slot| if (slot.state.load(.acquire) != 0) return;
        var b: [512]u8 = undefined;
        const result = std.fmt.bufPrint(&b, "{{\"attempts\":{d},\"copiedImages\":{d},\"droppedImages\":{d},\"writeFailed\":{},\"slots\":8}}", .{ stream_attempts, stream_copied, stream_dropped, stream_write_failed.load(.acquire) }) catch unreachable;
        var name: [80:0]u8 = @splat(0);
        const path = std.fmt.bufPrintZ(&name, "{s}.complete", .{std.mem.span(@as([*:0]const u8, &stream_label))}) catch unreachable;
        save(path, result) catch {
            disabled = true;
        };
        stream_finished = true;
        return;
    }
    var eligible: usize = 0;
    for (images, 0..) |im, index| {
        if (im.handle == null or im.inode == 0 or im.last_queue != q or im.submission != submission_id or !im.known or im.external_owner) continue;
        if (im.layout == v.VK_IMAGE_LAYOUT_UNDEFINED or im.layout == v.VK_IMAGE_LAYOUT_PREINITIALIZED) continue;
        eligible += 1;
        var free: ?*Slot = null;
        for (&slots) |*slot| if (slot.state.load(.acquire) == 0) {
            free = slot;
            break;
        };
        if (free) |slot| {
            slot.im = im;
            slot.index = index;
            slot.submission = submission_id;
            check(D("vkResetCommandPool")(device, slot.pool, 0)) catch {
                disabled = true;
                return;
            };
            // The slot fence is signaled from its last use, or newly unsignaled.
            check(D("vkResetFences")(device, 1, &slot.fence)) catch {
                disabled = true;
                return;
            };
            recordCopy(slot.cb, im, slot.buffer) catch {
                disabled = true;
                return;
            };
            var si = std.mem.zeroes(v.VkSubmitInfo);
            si.sType = v.VK_STRUCTURE_TYPE_SUBMIT_INFO;
            si.commandBufferCount = 1;
            si.pCommandBuffers = &slot.cb;
            slot.submitted_ns = monotonicNs();
            check(D("vkQueueSubmit")(q, 1, &si, slot.fence)) catch {
                disabled = true;
                return;
            };
            slot.state.store(1, .release);
            stream_copied += 1;
        } else stream_dropped += 1;
    }
    if (eligible > 0) {
        stream_remaining -= 1;
        stream_attempts += 1;
    }
}
fn stopStream() void {
    // Teardown is allowed to wait; the submission hot path never waits on a fence.
    for (&slots) |*slot| if (slot.state.load(.acquire) == 1) {
        const status = D("vkWaitForFences")(device, 1, &slot.fence, v.VK_TRUE, 2_000_000_000);
        if (status == v.VK_SUCCESS) slot.state.store(2, .release);
    };
    const deadline = monotonicNs() + 2_000_000_000;
    while (stream_thread != null and monotonicNs() < deadline) {
        var busy = false;
        for (&slots) |*slot| if (slot.state.load(.acquire) == 2) {
            busy = true;
        };
        if (!busy) break;
        const delay: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&delay, null);
    }
    stream_stop.store(true, .release);
    if (stream_thread) |t| t.join();
    stream_thread = null;
    for (&slots) |*slot| {
        if (slot.state.load(.acquire) == 1) continue; // Retain pending GPU resources until device destruction.
        if (slot.pixels != null) D("vkUnmapMemory")(device, slot.memory);
        if (slot.fence != null) D("vkDestroyFence")(device, slot.fence, null);
        if (slot.pool != null) D("vkDestroyCommandPool")(device, slot.pool, null);
        if (slot.buffer != null) D("vkDestroyBuffer")(device, slot.buffer, null);
        if (slot.memory != null) D("vkFreeMemory")(device, slot.memory, null);
    }
    if (stream_fd >= 0) {
        _ = linux.close(stream_fd);
        stream_fd = -1;
    }
}
test "marker measurement honors channel order and reports exact moments" {
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 255, 0, 255 };
    const red = markerPixels(&rgba, 2, 2, false);
    try std.testing.expectEqual(@as(u64, 2), red.count);
    try std.testing.expectEqual(@as(u64, 0), red.sum_x);
    try std.testing.expectEqual(@as(u64, 1), red.sum_y);
    const blue = markerPixels(&rgba, 2, 2, true);
    try std.testing.expectEqual(@as(u64, 1), blue.count);
    try std.testing.expectEqual(@as(u64, 1), blue.sum_x);
}

test "wrist marker moments exclude desktop region, white pixels and nonmagenta colors" {
    const pixels = try std.testing.allocator.alloc(u8, 960 * 960 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    for ([_][2]usize{ .{ 10, 700 }, .{ 20, 800 }, .{ 500, 400 } }) |point| {
        const i = (point[1] * 960 + point[0]) * 4;
        pixels[i] = 255;
        pixels[i + 2] = 255;
    }
    const white = (750 * 960 + 30) * 4;
    pixels[white] = 255;
    pixels[white + 1] = 255;
    pixels[white + 2] = 255;
    const result = wristPixels(pixels.ptr, 960, 960);
    try std.testing.expectEqual(@as(u64, 2), result.count);
    try std.testing.expectEqual(@as(u64, 30), result.sum_x);
    try std.testing.expectEqual(@as(u64, 1500), result.sum_y);
}
