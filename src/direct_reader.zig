//! Lab readback of driver-direct swap images, whichever process rendered them.
//!
//! Follows ALVR's Linux import (alvr/server_openvr/cpp/platform/linux/Renderer.cpp at
//! ebec107b7e5f81677fb9c631d239daf2110bf573): each image's shared fd is imported into a private
//! Vulkan device as an opaque fd, with the create info the image was allocated with
//! (MUTABLE_FORMAT, TRANSFER_SRC | SAMPLED | INPUT_ATTACHMENT, optimal tiling, dedicated
//! allocation), then copied to host memory. Unlike ALVR the image keeps its GENERAL layout:
//! a layout transition could rewrite compression metadata in memory the producer still owns.
//! There is no usable producer fence here (GPU-READBACK.md); callers read a presented frame.
const std = @import("std");
const linux = std.os.linux;
const v = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vulkan_core.h");
});
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

var mutex: std.Io.Mutex = .init;
var library: ?*anyopaque = null;
var gipa: v.PFN_vkGetInstanceProcAddr = null;
var gdpa: v.PFN_vkGetDeviceProcAddr = null;
var instance: v.VkInstance = null;
var physical: v.VkPhysicalDevice = null;
var device: v.VkDevice = null;
var queue: v.VkQueue = null;
var family: u32 = 0;

fn fnType(comptime name: []const u8) type {
    return @typeInfo(@field(v, "PFN_" ++ name)).optional.child;
}
fn I(comptime name: [:0]const u8) !fnType(name) {
    return @ptrCast(gipa.?(instance, name) orelse return error.MissingVulkanFunction);
}
fn D(comptime name: [:0]const u8) !fnType(name) {
    return @ptrCast(gdpa.?(device, name) orelse return error.MissingVulkanFunction);
}
/// Best-effort device call for cleanup paths.
fn call(comptime name: [:0]const u8, args: anytype) void {
    const f = D(name) catch return;
    _ = @call(.auto, f, args);
}
fn check(result: v.VkResult) !void {
    if (result != v.VK_SUCCESS) return error.VulkanFailure;
}

/// One swap image to read. `fd` is a duplicate owned by the call: consumed whether or not it succeeds.
pub const Source = struct { fd: i32, width: u32, height: u32, format: u32 };

fn init() !void {
    if (device != null) return;
    library = library orelse dlopen("libvulkan.so.1", 2) orelse return error.NoVulkanLoader;
    gipa = @ptrCast(dlsym(library, "vkGetInstanceProcAddr") orelse return error.NoVulkanLoader);
    var app = std.mem.zeroes(v.VkApplicationInfo);
    app.sType = v.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "petplay driver-direct reader";
    app.apiVersion = (1 << 22) | (1 << 12); // Vulkan 1.1: external memory, dedicated allocation.
    var ici = std.mem.zeroes(v.VkInstanceCreateInfo);
    ici.sType = v.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    try check((try I("vkCreateInstance"))(&ici, null, &instance));
    errdefer {
        if (I("vkDestroyInstance")) |destroy| destroy(instance, null) else |_| {}
        instance = null;
        physical = null;
    }
    var devices: [8]v.VkPhysicalDevice = undefined;
    var count: u32 = devices.len;
    const enumerated = (try I("vkEnumeratePhysicalDevices"))(instance, &count, &devices);
    if (enumerated != v.VK_SUCCESS and enumerated != v.VK_INCOMPLETE) return error.VulkanFailure;
    // Opaque-fd import only works on the exporting GPU. The lab machine has one; skip CPU devices.
    for (devices[0..count]) |candidate| {
        var props: v.VkPhysicalDeviceProperties = undefined;
        (try I("vkGetPhysicalDeviceProperties"))(candidate, &props);
        if (props.deviceType == v.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU or props.deviceType == v.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) {
            physical = candidate;
            break;
        }
    }
    if (physical == null) return error.NoGpu;
    var families: [16]v.VkQueueFamilyProperties = undefined;
    var family_count: u32 = families.len;
    (try I("vkGetPhysicalDeviceQueueFamilyProperties"))(physical, &family_count, &families);
    family = for (families[0..family_count], 0..) |f, i| {
        if (f.queueFlags & (v.VK_QUEUE_GRAPHICS_BIT | v.VK_QUEUE_TRANSFER_BIT) != 0) break @intCast(i);
    } else return error.NoTransferQueue;
    const priority: f32 = 1;
    var qci = std.mem.zeroes(v.VkDeviceQueueCreateInfo);
    qci.sType = v.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    const extensions = [_][*:0]const u8{"VK_KHR_external_memory_fd"};
    var dci = std.mem.zeroes(v.VkDeviceCreateInfo);
    dci.sType = v.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = extensions.len;
    dci.ppEnabledExtensionNames = @ptrCast(&extensions);
    try check((try I("vkCreateDevice"))(physical, &dci, null, &device));
    gdpa = try I("vkGetDeviceProcAddr");
    (try D("vkGetDeviceQueue"))(device, family, 0, &queue);
}

pub fn deinit() void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (device != null) call("vkDestroyDevice", .{ device, null });
    if (instance != null) {
        if (I("vkDestroyInstance")) |destroy| destroy(instance, null) else |_| {}
    }
    device = null;
    instance = null;
    physical = null;
    queue = null;
}

fn memoryType(bits: u32, flags: u32) !u32 {
    var props: v.VkPhysicalDeviceMemoryProperties = undefined;
    (try I("vkGetPhysicalDeviceMemoryProperties"))(physical, &props);
    for (props.memoryTypes[0..props.memoryTypeCount], 0..) |t, i| {
        if ((bits & (@as(u32, 1) << @intCast(i))) != 0 and (t.propertyFlags & flags) == flags) return @intCast(i);
    }
    return error.NoMemoryType;
}

/// Copies `source` into `out` (width × height × 4 bytes, the image's own channel order).
pub fn read(source: Source, out: []u8) !void {
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(source.fd);
    };
    if (out.len != @as(usize, source.width) * source.height * 4) return error.WrongOutputSize;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    try init();

    var image: v.VkImage = null;
    var image_memory: v.VkDeviceMemory = null;
    var buffer: v.VkBuffer = null;
    var buffer_memory: v.VkDeviceMemory = null;
    var pool: v.VkCommandPool = null;
    var fence: v.VkFence = null;
    var pending = false;
    defer {
        if (pending) call("vkDeviceWaitIdle", .{device});
        if (fence != null) call("vkDestroyFence", .{ device, fence, null });
        if (pool != null) call("vkDestroyCommandPool", .{ device, pool, null });
        if (buffer != null) call("vkDestroyBuffer", .{ device, buffer, null });
        if (buffer_memory != null) call("vkFreeMemory", .{ device, buffer_memory, null });
        if (image != null) call("vkDestroyImage", .{ device, image, null });
        if (image_memory != null) call("vkFreeMemory", .{ device, image_memory, null });
    }

    var external = std.mem.zeroes(v.VkExternalMemoryImageCreateInfo);
    external.sType = v.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
    external.handleTypes = v.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    var ici = std.mem.zeroes(v.VkImageCreateInfo);
    ici.sType = v.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ici.pNext = &external;
    ici.flags = v.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
    ici.imageType = v.VK_IMAGE_TYPE_2D;
    ici.format = source.format;
    ici.extent = .{ .width = source.width, .height = source.height, .depth = 1 };
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = v.VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = v.VK_IMAGE_TILING_OPTIMAL;
    ici.usage = v.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | v.VK_IMAGE_USAGE_SAMPLED_BIT | v.VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
    ici.sharingMode = v.VK_SHARING_MODE_EXCLUSIVE;
    ici.initialLayout = v.VK_IMAGE_LAYOUT_UNDEFINED;
    try check((try D("vkCreateImage"))(device, &ici, null, &image));

    var dedicated_reqs = std.mem.zeroes(v.VkMemoryDedicatedRequirements);
    dedicated_reqs.sType = v.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS;
    var reqs = std.mem.zeroes(v.VkMemoryRequirements2);
    reqs.sType = v.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
    reqs.pNext = &dedicated_reqs;
    var reqs_info = std.mem.zeroes(v.VkImageMemoryRequirementsInfo2);
    reqs_info.sType = v.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2;
    reqs_info.image = image;
    (try D("vkGetImageMemoryRequirements2"))(device, &reqs_info, &reqs);
    var import = std.mem.zeroes(v.VkImportMemoryFdInfoKHR);
    import.sType = v.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR;
    import.handleType = v.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    import.fd = source.fd;
    var dedicated = std.mem.zeroes(v.VkMemoryDedicatedAllocateInfo);
    dedicated.sType = v.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
    dedicated.pNext = &import;
    dedicated.image = image;
    var mai = std.mem.zeroes(v.VkMemoryAllocateInfo);
    mai.sType = v.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.pNext = &dedicated;
    mai.allocationSize = reqs.memoryRequirements.size;
    mai.memoryTypeIndex = try memoryType(reqs.memoryRequirements.memoryTypeBits, v.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try check((try D("vkAllocateMemory"))(device, &mai, null, &image_memory));
    fd_owned = false; // A successful import transfers the fd to Vulkan.
    try check((try D("vkBindImageMemory"))(device, image, image_memory, 0));

    var bci = std.mem.zeroes(v.VkBufferCreateInfo);
    bci.sType = v.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = out.len;
    bci.usage = v.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = v.VK_SHARING_MODE_EXCLUSIVE;
    try check((try D("vkCreateBuffer"))(device, &bci, null, &buffer));
    var buffer_reqs: v.VkMemoryRequirements = undefined;
    (try D("vkGetBufferMemoryRequirements"))(device, buffer, &buffer_reqs);
    var bai = std.mem.zeroes(v.VkMemoryAllocateInfo);
    bai.sType = v.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bai.allocationSize = buffer_reqs.size;
    bai.memoryTypeIndex = try memoryType(buffer_reqs.memoryTypeBits, v.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | v.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    try check((try D("vkAllocateMemory"))(device, &bai, null, &buffer_memory));
    try check((try D("vkBindBufferMemory"))(device, buffer, buffer_memory, 0));

    var pci = std.mem.zeroes(v.VkCommandPoolCreateInfo);
    pci.sType = v.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex = family;
    try check((try D("vkCreateCommandPool"))(device, &pci, null, &pool));
    var cb: v.VkCommandBuffer = null;
    var cai = std.mem.zeroes(v.VkCommandBufferAllocateInfo);
    cai.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cai.commandPool = pool;
    cai.level = v.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    try check((try D("vkAllocateCommandBuffers"))(device, &cai, &cb));
    var begin = std.mem.zeroes(v.VkCommandBufferBeginInfo);
    begin.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = v.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try check((try D("vkBeginCommandBuffer"))(cb, &begin));
    // Memory dependency only (GENERAL → GENERAL): see the module comment.
    var barrier = std.mem.zeroes(v.VkImageMemoryBarrier);
    barrier.sType = v.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = v.VK_ACCESS_MEMORY_WRITE_BIT;
    barrier.dstAccessMask = v.VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout = v.VK_IMAGE_LAYOUT_GENERAL;
    barrier.newLayout = v.VK_IMAGE_LAYOUT_GENERAL;
    barrier.srcQueueFamilyIndex = v.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = v.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange = .{ .aspectMask = v.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    (try D("vkCmdPipelineBarrier"))(cb, v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, v.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
    var region = std.mem.zeroes(v.VkBufferImageCopy);
    region.imageSubresource = .{ .aspectMask = v.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    region.imageExtent = .{ .width = source.width, .height = source.height, .depth = 1 };
    (try D("vkCmdCopyImageToBuffer"))(cb, image, v.VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &region);
    try check((try D("vkEndCommandBuffer"))(cb));
    var fci = std.mem.zeroes(v.VkFenceCreateInfo);
    fci.sType = v.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    try check((try D("vkCreateFence"))(device, &fci, null, &fence));
    var si = std.mem.zeroes(v.VkSubmitInfo);
    si.sType = v.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    try check((try D("vkQueueSubmit"))(queue, 1, &si, fence));
    pending = true;
    try check((try D("vkWaitForFences"))(device, 1, &fence, v.VK_TRUE, 1_000_000_000));
    pending = false;
    var mapped: ?*anyopaque = null;
    try check((try D("vkMapMemory"))(device, buffer_memory, 0, out.len, 0, &mapped));
    defer call("vkUnmapMemory", .{ device, buffer_memory });
    @memcpy(out, @as([*]const u8, @ptrCast(mapped.?))[0..out.len]);
}
