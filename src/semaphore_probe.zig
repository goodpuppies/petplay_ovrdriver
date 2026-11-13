//! Imports a runtime-allocated shared timeline semaphore and samples its counter.
//!
//! `NewSharedVulkanSemaphore(bCounting=true)` gives the driver a timeline semaphore it can
//! export as an opaque fd (see direct.zig). Obtaining one does not oblige SteamVR to signal
//! it. This module answers the remaining question empirically: import the exported payload
//! into a private Vulkan device and watch whether the counter ever advances while the
//! compositor is presenting. A counter that never moves is as useless as the stale dma-buf
//! reservation fence in GPU-READBACK.md, and says so explicitly rather than by omission.
const std = @import("std");
const linux = std.os.linux;
const v = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vulkan_core.h");
});
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

var library: ?*anyopaque = null;
var gipa: v.PFN_vkGetInstanceProcAddr = null;
var gdpa: v.PFN_vkGetDeviceProcAddr = null;
var instance: v.VkInstance = null;
var device: v.VkDevice = null;
var semaphore: v.VkSemaphore = null;

fn fnType(comptime name: []const u8) type {
    return @typeInfo(@field(v, "PFN_" ++ name)).optional.child;
}
fn I(comptime name: [:0]const u8) !fnType(name) {
    return @ptrCast(gipa.?(instance, name) orelse return error.MissingVulkanFunction);
}
fn D(comptime name: [:0]const u8) !fnType(name) {
    return @ptrCast(gdpa.?(device, name) orelse return error.MissingVulkanFunction);
}
fn check(result: v.VkResult) !void {
    if (result != v.VK_SUCCESS) return error.VulkanFailure;
}

fn initDevice() !void {
    if (device != null) return;
    library = library orelse dlopen("libvulkan.so.1", 2) orelse return error.NoVulkanLoader;
    gipa = @ptrCast(dlsym(library, "vkGetInstanceProcAddr") orelse return error.NoVulkanLoader);
    var app = std.mem.zeroes(v.VkApplicationInfo);
    app.sType = v.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "petplay semaphore probe";
    app.apiVersion = (1 << 22) | (2 << 12); // Vulkan 1.2: timeline semaphores are core.
    var ici = std.mem.zeroes(v.VkInstanceCreateInfo);
    ici.sType = v.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    try check((try I("vkCreateInstance"))(&ici, null, &instance));
    errdefer {
        if (I("vkDestroyInstance")) |destroy| destroy(instance, null) else |_| {}
        instance = null;
    }
    var devices: [8]v.VkPhysicalDevice = undefined;
    var count: u32 = devices.len;
    const enumerated = (try I("vkEnumeratePhysicalDevices"))(instance, &count, &devices);
    if (enumerated != v.VK_SUCCESS and enumerated != v.VK_INCOMPLETE) return error.VulkanFailure;
    // An opaque-fd payload is only importable on the GPU that exported it.
    var physical: v.VkPhysicalDevice = null;
    for (devices[0..count]) |candidate| {
        var props: v.VkPhysicalDeviceProperties = undefined;
        (try I("vkGetPhysicalDeviceProperties"))(candidate, &props);
        if (props.deviceType == v.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU or props.deviceType == v.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) {
            physical = candidate;
            break;
        }
    }
    if (physical == null) return error.NoGpu;
    var families: u32 = 0;
    (try I("vkGetPhysicalDeviceQueueFamilyProperties"))(physical, &families, null);
    if (families == 0) return error.NoQueueFamily;
    const priority: f32 = 1.0;
    var qci = std.mem.zeroes(v.VkDeviceQueueCreateInfo);
    qci.sType = v.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = 0;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    var timeline = std.mem.zeroes(v.VkPhysicalDeviceTimelineSemaphoreFeatures);
    timeline.sType = v.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
    timeline.timelineSemaphore = v.VK_TRUE;
    const extensions = [_][*c]const u8{"VK_KHR_external_semaphore_fd"};
    var dci = std.mem.zeroes(v.VkDeviceCreateInfo);
    dci.sType = v.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.pNext = &timeline;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = extensions.len;
    dci.ppEnabledExtensionNames = &extensions;
    try check((try I("vkCreateDevice"))(physical, &dci, null, &device));
    gdpa = @ptrCast(gipa.?(instance, "vkGetDeviceProcAddr").?);
}

/// Imports `fd` (consumed on success and on failure) as a timeline semaphore payload.
pub fn start(fd: i32) !void {
    errdefer _ = linux.close(fd);
    try initDevice();
    if (semaphore != null) return error.AlreadyWatching;
    var type_info = std.mem.zeroes(v.VkSemaphoreTypeCreateInfo);
    type_info.sType = v.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    type_info.semaphoreType = v.VK_SEMAPHORE_TYPE_TIMELINE;
    type_info.initialValue = 0;
    var sci = std.mem.zeroes(v.VkSemaphoreCreateInfo);
    sci.sType = v.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    sci.pNext = &type_info;
    try check((try D("vkCreateSemaphore"))(device, &sci, null, &semaphore));
    errdefer {
        if (D("vkDestroySemaphore")) |destroy| destroy(device, semaphore, null) else |_| {}
        semaphore = null;
    }
    var import = std.mem.zeroes(v.VkImportSemaphoreFdInfoKHR);
    import.sType = v.VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR;
    import.semaphore = semaphore;
    import.flags = 0; // Permanent: the probe owns this payload reference for its lifetime.
    import.handleType = v.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    import.fd = fd;
    // A successful import transfers ownership of the fd to Vulkan.
    try check((try D("vkImportSemaphoreFdKHR"))(device, &import));
}
/// Current counter value, or null if there is nothing imported or the read failed.
pub fn sample() ?u64 {
    if (semaphore == null) return null;
    const get = D("vkGetSemaphoreCounterValue") catch return null;
    var value: u64 = 0;
    if (get(device, semaphore, &value) != v.VK_SUCCESS) return null;
    return value;
}
pub fn stop() void {
    if (semaphore != null) {
        if (D("vkDestroySemaphore")) |destroy| destroy(device, semaphore, null) else |_| {}
        semaphore = null;
    }
}
pub fn deinit() void {
    stop();
    if (device != null) {
        if (D("vkDestroyDevice")) |destroy| destroy(device, null) else |_| {}
        device = null;
    }
    if (instance != null) {
        if (I("vkDestroyInstance")) |destroy| destroy(instance, null) else |_| {}
        instance = null;
    }
}
