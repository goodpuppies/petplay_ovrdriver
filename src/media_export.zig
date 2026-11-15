//! Bounded GPU-only export. Slots return only on exact encoder acknowledgments.
//! The copy signals a SYNC_FD for the codec worker and a separate present semaphore.
const std = @import("std");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
pub fn Exporter(comptime v: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { image: v.VkImage = null, memory: v.VkDeviceMemory = null, pool: v.VkCommandPool = null, cmd: v.VkCommandBuffer = null, fence: v.VkFence = null, ready: v.VkSemaphore = null, dma: i32 = -1, pitch: u32 = 0, offset: u32 = 0, sequence: u64 = 0, busy: bool = false, used: bool = false, discarded: bool = false };
        var slots: [3]Slot = @splat(.{});
        var completions: [8]struct { image: v.VkImage = null, semaphore: v.VkSemaphore = null } = @splat(.{});
        var dev: v.VkDevice = null;
        var pd: v.VkPhysicalDevice = null;
        var inst: v.VkInstance = null;
        var gdpa: v.PFN_vkGetDeviceProcAddr = null;
        var gipa: v.PFN_vkGetInstanceProcAddr = null;
        var socket: i32 = -1;
        var attempted = false;
        var failed = false;
        var sequence: u64 = 0;
        /// The headless display's size; every slot, copy and descriptor uses it.
        pub var width: u32 = 1920;
        pub var height: u32 = 1080;
        var sent: u64 = 0;
        var dropped: u64 = 0;
        var released: u64 = 0;
        fn T(comptime name: []const u8) type {
            return @typeInfo(@field(v, "PFN_" ++ name)).optional.child;
        }
        fn D(comptime name: [:0]const u8) T(name) {
            return @ptrCast(gdpa.?(dev, name).?);
        }
        fn I(comptime name: [:0]const u8) T(name) {
            return @ptrCast(gipa.?(inst, name).?);
        }
        fn check(r: v.VkResult) !void {
            if (r != v.VK_SUCCESS) return error.VulkanMediaExport;
        }
        fn log(comptime fmt: []const u8, args: anytype) void {
            var buf: [384]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "PetPlay media: " ++ fmt ++ "\n", args) catch return;
            _ = linux.write(2, s.ptr, s.len);
        }
        pub fn requested() bool {
            return getenv("PP_MEDIA_SOCKET") != null;
        }
        pub fn init(p: v.VkPhysicalDevice, d: v.VkDevice, i: v.VkInstance, g: v.PFN_vkGetDeviceProcAddr, ip: v.PFN_vkGetInstanceProcAddr) void {
            pd = p;
            dev = d;
            inst = i;
            gdpa = g;
            gipa = ip;
        }
        fn now() u64 {
            var t: linux.timespec = undefined;
            if (linux.errno(linux.clock_gettime(.MONOTONIC, &t)) != .SUCCESS) return 0;
            return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
        }
        fn open(family: u32) !void {
            const path = std.mem.span(getenv("PP_MEDIA_SOCKET") orelse return error.NoMediaSocket);
            if (path.len == 0 or path.len >= 108 or path[0] != '/') return error.InvalidSocket;
            socket = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
            if (socket < 0) return error.Socket;
            var address = std.mem.zeroes(c.struct_sockaddr_un);
            address.sun_family = c.AF_UNIX;
            @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);
            if (c.connect(socket, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.Connect;
            for (&slots) |*s| try createSlot(s, family);
            log("pool ready slots=3 BGRA={d}x{d} modifier=0 raw_cpu_bytes=0", .{ width, height });
        }
        fn createSlot(s: *Slot, family: u32) !void {
            var modifier_info = std.mem.zeroes(v.VkPhysicalDeviceImageDrmFormatModifierInfoEXT);
            modifier_info.sType = v.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT;
            modifier_info.sharingMode = v.VK_SHARING_MODE_EXCLUSIVE;
            var external = std.mem.zeroes(v.VkPhysicalDeviceExternalImageFormatInfo);
            external.sType = v.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO;
            external.handleType = v.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
            external.pNext = &modifier_info;
            var format = std.mem.zeroes(v.VkPhysicalDeviceImageFormatInfo2);
            format.sType = v.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
            format.pNext = &external;
            format.format = v.VK_FORMAT_B8G8R8A8_UNORM;
            format.type = v.VK_IMAGE_TYPE_2D;
            format.tiling = v.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
            format.usage = v.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
            var props = std.mem.zeroes(v.VkExternalImageFormatProperties);
            props.sType = v.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
            var fp = std.mem.zeroes(v.VkImageFormatProperties2);
            fp.sType = v.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
            fp.pNext = &props;
            try check(I("vkGetPhysicalDeviceImageFormatProperties2")(pd, &format, &fp));
            if (props.externalMemoryProperties.externalMemoryFeatures & v.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT == 0) return error.NotExportable;
            const zero: u64 = 0;
            var ml = std.mem.zeroes(v.VkImageDrmFormatModifierListCreateInfoEXT);
            ml.sType = v.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT;
            ml.drmFormatModifierCount = 1;
            ml.pDrmFormatModifiers = &zero;
            var ei = std.mem.zeroes(v.VkExternalMemoryImageCreateInfo);
            ei.sType = v.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
            ei.handleTypes = external.handleType;
            ei.pNext = &ml;
            var ci = std.mem.zeroes(v.VkImageCreateInfo);
            ci.sType = v.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            ci.pNext = &ei;
            ci.imageType = v.VK_IMAGE_TYPE_2D;
            ci.format = format.format;
            ci.extent = .{ .width = width, .height = height, .depth = 1 };
            ci.mipLevels = 1;
            ci.arrayLayers = 1;
            ci.samples = v.VK_SAMPLE_COUNT_1_BIT;
            ci.tiling = format.tiling;
            ci.usage = format.usage;
            ci.sharingMode = v.VK_SHARING_MODE_EXCLUSIVE;
            try check(D("vkCreateImage")(dev, &ci, null, &s.image));
            var req: v.VkMemoryRequirements = undefined;
            D("vkGetImageMemoryRequirements")(dev, s.image, &req);
            var mp: v.VkPhysicalDeviceMemoryProperties = undefined;
            I("vkGetPhysicalDeviceMemoryProperties")(pd, &mp);
            var memory_type: ?u32 = null;
            for (mp.memoryTypes[0..mp.memoryTypeCount], 0..) |m, i| if (req.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and m.propertyFlags & v.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0) {
                memory_type = @intCast(i);
                break;
            };
            var dedicated = std.mem.zeroes(v.VkMemoryDedicatedAllocateInfo);
            dedicated.sType = v.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
            dedicated.image = s.image;
            var exp = std.mem.zeroes(v.VkExportMemoryAllocateInfo);
            exp.sType = v.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
            exp.pNext = &dedicated;
            exp.handleTypes = external.handleType;
            var ma = std.mem.zeroes(v.VkMemoryAllocateInfo);
            ma.sType = v.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            ma.pNext = &exp;
            ma.allocationSize = req.size;
            ma.memoryTypeIndex = memory_type orelse return error.NoDeviceMemory;
            try check(D("vkAllocateMemory")(dev, &ma, null, &s.memory));
            try check(D("vkBindImageMemory")(dev, s.image, s.memory, 0));
            var sub = v.VkImageSubresource{ .aspectMask = v.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT, .mipLevel = 0, .arrayLayer = 0 };
            var layout: v.VkSubresourceLayout = undefined;
            D("vkGetImageSubresourceLayout")(dev, s.image, &sub, &layout);
            s.pitch = std.math.cast(u32, layout.rowPitch) orelse return error.LayoutOverflow;
            s.offset = std.math.cast(u32, layout.offset) orelse return error.LayoutOverflow;
            var fd = std.mem.zeroes(v.VkMemoryGetFdInfoKHR);
            fd.sType = v.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
            fd.memory = s.memory;
            fd.handleType = external.handleType;
            try check(D("vkGetMemoryFdKHR")(dev, &fd, &s.dma));
            var pci = std.mem.zeroes(v.VkCommandPoolCreateInfo);
            pci.sType = v.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            pci.queueFamilyIndex = family;
            pci.flags = v.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            try check(D("vkCreateCommandPool")(dev, &pci, null, &s.pool));
            var cai = std.mem.zeroes(v.VkCommandBufferAllocateInfo);
            cai.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            cai.commandPool = s.pool;
            cai.level = v.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            cai.commandBufferCount = 1;
            try check(D("vkAllocateCommandBuffers")(dev, &cai, &s.cmd));
            var fc = std.mem.zeroes(v.VkFenceCreateInfo);
            fc.sType = v.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            try check(D("vkCreateFence")(dev, &fc, null, &s.fence));
            var export_sem = std.mem.zeroes(v.VkExportSemaphoreCreateInfo);
            export_sem.sType = v.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO;
            export_sem.handleTypes = v.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            var sc = std.mem.zeroes(v.VkSemaphoreCreateInfo);
            sc.sType = v.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
            sc.pNext = &export_sem;
            try check(D("vkCreateSemaphore")(dev, &sc, null, &s.ready));
        }
        fn acks() !void {
            while (true) {
                var ack: [16]u8 = undefined;
                const n = c.recv(socket, &ack, ack.len, c.MSG_DONTWAIT | c.MSG_TRUNC);
                if (n < 0) {
                    if (c.__errno_location().* == c.EAGAIN) return;
                    return error.Receive;
                }
                if (n != ack.len) return error.Disconnected;
                if (std.mem.readInt(u32, ack[0..4], .little) != 0x50504d31) return error.InvalidAck;
                const index = std.mem.readInt(u32, ack[4..8], .little);
                const seq = std.mem.readInt(u64, ack[8..16], .little);
                if (index >= slots.len or !slots[index].busy or slots[index].discarded or slots[index].sequence != seq) return error.InvalidAck;
                slots[index].busy = false;
                released += 1;
            }
        }
        pub fn capture(queue: v.VkQueue, family: u32, source: v.VkImage, waits: []const v.VkSemaphore) ?v.VkSemaphore {
            if (!requested() or failed) return null;
            if (!attempted) {
                attempted = true;
                open(family) catch |err| {
                    failed = true;
                    log("disabled: {s}", .{@errorName(err)});
                    return null;
                };
            }
            acks() catch |err| {
                failed = true;
                log("disabled: {s}", .{@errorName(err)});
                return null;
            };
            for (&slots) |*s| if (s.discarded and D("vkGetFenceStatus")(dev, s.fence) == v.VK_SUCCESS) {
                s.discarded = false;
                s.busy = false;
            };
            sequence += 1;
            for (&slots, 0..) |*s, index| if (!s.busy) {
                if (s.used and D("vkGetFenceStatus")(dev, s.fence) != v.VK_SUCCESS) continue;
                const completion = presentSemaphore(source) catch {
                    failed = true;
                    return null;
                };
                submit(s, queue, family, source, waits, index, completion) catch |err| {
                    failed = true;
                    log("disabled: {s}", .{@errorName(err)});
                    return null;
                };
                return completion;
            };
            dropped += 1;
            return null;
        }
        fn presentSemaphore(source: v.VkImage) !v.VkSemaphore {
            // A swapchain image can be presented again only after acquisition has
            // established completion of its previous present wait. An encoder slot
            // acknowledgment by itself does not establish that semaphore lifetime.
            for (completions) |entry| if (entry.image == source) return entry.semaphore;
            for (&completions) |*entry| if (entry.image == null) {
                var ci = std.mem.zeroes(v.VkSemaphoreCreateInfo);
                ci.sType = v.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
                try check(D("vkCreateSemaphore")(dev, &ci, null, &entry.semaphore));
                entry.image = source;
                return entry.semaphore;
            };
            return error.TooManySwapchainImages;
        }
        fn put32(b: []u8, i: usize, x: u32) void {
            std.mem.writeInt(u32, b[i..][0..4], x, .little);
        }
        fn put64(b: []u8, i: usize, x: u64) void {
            std.mem.writeInt(u64, b[i..][0..8], x, .little);
        }
        fn submit(s: *Slot, q: v.VkQueue, family: u32, source: v.VkImage, waits: []const v.VkSemaphore, index: usize, completion: v.VkSemaphore) !void {
            if (waits.len > 8) return error.TooManyWaits;
            if (s.used) {
                try check(D("vkResetFences")(dev, 1, &s.fence));
                try check(D("vkResetCommandBuffer")(s.cmd, 0));
            }
            var bi = std.mem.zeroes(v.VkCommandBufferBeginInfo);
            bi.sType = v.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            bi.flags = v.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            try check(D("vkBeginCommandBuffer")(s.cmd, &bi));
            var barriers: [2]v.VkImageMemoryBarrier = @splat(std.mem.zeroes(v.VkImageMemoryBarrier));
            for (&barriers) |*b| {
                b.sType = v.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
                b.srcQueueFamilyIndex = v.VK_QUEUE_FAMILY_IGNORED;
                b.dstQueueFamilyIndex = v.VK_QUEUE_FAMILY_IGNORED;
                b.subresourceRange = .{ .aspectMask = v.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            }
            barriers[0].image = source;
            barriers[0].oldLayout = v.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
            barriers[0].newLayout = v.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            barriers[0].dstAccessMask = v.VK_ACCESS_TRANSFER_READ_BIT;
            barriers[1].image = s.image;
            barriers[1].oldLayout = if (s.used) v.VK_IMAGE_LAYOUT_GENERAL else v.VK_IMAGE_LAYOUT_UNDEFINED;
            barriers[1].newLayout = v.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barriers[1].dstAccessMask = v.VK_ACCESS_TRANSFER_WRITE_BIT;
            if (s.used) {
                barriers[1].srcQueueFamilyIndex = v.VK_QUEUE_FAMILY_EXTERNAL;
                barriers[1].dstQueueFamilyIndex = family;
            }
            D("vkCmdPipelineBarrier")(s.cmd, v.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, v.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 2, &barriers);
            var region = std.mem.zeroes(v.VkImageCopy);
            region.srcSubresource = .{ .aspectMask = v.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
            region.dstSubresource = region.srcSubresource;
            region.extent = .{ .width = width, .height = height, .depth = 1 };
            D("vkCmdCopyImage")(s.cmd, source, v.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, s.image, v.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            barriers[0].oldLayout = v.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            barriers[0].newLayout = v.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
            barriers[0].srcAccessMask = v.VK_ACCESS_TRANSFER_READ_BIT;
            barriers[0].dstAccessMask = 0;
            barriers[1].oldLayout = v.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barriers[1].newLayout = v.VK_IMAGE_LAYOUT_GENERAL;
            barriers[1].srcAccessMask = v.VK_ACCESS_TRANSFER_WRITE_BIT;
            barriers[1].dstAccessMask = 0;
            barriers[1].srcQueueFamilyIndex = family;
            barriers[1].dstQueueFamilyIndex = v.VK_QUEUE_FAMILY_EXTERNAL;
            D("vkCmdPipelineBarrier")(s.cmd, v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 2, &barriers);
            try check(D("vkEndCommandBuffer")(s.cmd));
            const stages: [8]v.VkPipelineStageFlags = @splat(v.VK_PIPELINE_STAGE_TRANSFER_BIT);
            const signals = [_]v.VkSemaphore{ s.ready, completion };
            var si = std.mem.zeroes(v.VkSubmitInfo);
            si.sType = v.VK_STRUCTURE_TYPE_SUBMIT_INFO;
            si.waitSemaphoreCount = @intCast(waits.len);
            si.pWaitSemaphores = waits.ptr;
            si.pWaitDstStageMask = &stages;
            si.commandBufferCount = 1;
            si.pCommandBuffers = &s.cmd;
            si.signalSemaphoreCount = 2;
            si.pSignalSemaphores = &signals;
            try check(D("vkQueueSubmit")(q, 1, &si, s.fence));
            s.busy = true;
            s.used = true;
            s.sequence = sequence;
            // From here the present MUST wait on completion, including any IPC failure.
            // Export/send errors disable media while returning that completion semaphore.
            sendFrame(s, index) catch |err| {
                failed = true;
                s.discarded = true;
                log("send disabled after GPU submit: {s}", .{@errorName(err)});
            };
        }
        fn sendFrame(s: *Slot, index: usize) !void {
            var info = std.mem.zeroes(v.VkSemaphoreGetFdInfoKHR);
            info.sType = v.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            info.semaphore = s.ready;
            info.handleType = v.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            var ready_fd: i32 = -1;
            try check(D("vkGetSemaphoreFdKHR")(dev, &info, &ready_fd));
            defer if (ready_fd >= 0) {
                _ = c.close(ready_fd);
            };
            // SYNC_FD -1 is an already-signalled payload and needs no second FD.
            var data: [64]u8 = @splat(0);
            put32(&data, 0, 0x50504d31);
            put32(&data, 4, 1);
            put32(&data, 8, @intCast(index));
            put32(&data, 12, if (ready_fd < 0) 1 else 0);
            put64(&data, 16, s.sequence);
            put64(&data, 24, now());
            put32(&data, 32, width);
            put32(&data, 36, height);
            put32(&data, 40, s.pitch);
            put32(&data, 44, s.offset);
            put64(&data, 48, 0);
            put32(&data, 56, v.VK_FORMAT_B8G8R8A8_UNORM);
            const Rights = extern struct { header: c.struct_cmsghdr, fds: [2]c_int };
            var rights = std.mem.zeroes(Rights);
            rights.header.cmsg_len = if (ready_fd < 0) @sizeOf(c.struct_cmsghdr) + @sizeOf(i32) else @sizeOf(Rights);
            rights.header.cmsg_level = c.SOL_SOCKET;
            rights.header.cmsg_type = c.SCM_RIGHTS;
            rights.fds = .{ s.dma, ready_fd };
            var io = c.struct_iovec{ .iov_base = &data, .iov_len = data.len };
            var msg = std.mem.zeroes(c.struct_msghdr);
            msg.msg_iov = &io;
            msg.msg_iovlen = 1;
            msg.msg_control = &rights;
            msg.msg_controllen = @sizeOf(Rights);
            if (c.sendmsg(socket, &msg, c.MSG_DONTWAIT | c.MSG_NOSIGNAL) != data.len) return error.Send;
            sent += 1;
            if (sent <= 3 or sent % 75 == 0) log("sent={d} released={d} dropped={d} slots=3", .{ sent, released, dropped });
        }
        pub fn stop() void {
            if (!attempted) return;
            if (socket >= 0) {
                // Only teardown waits: finish already-sent codec reads before freeing
                // the pool. The compositor's steady-state capture never waits here.
                _ = c.shutdown(socket, c.SHUT_WR);
                const deadline = now() + 2_000_000_000;
                while (now() < deadline) {
                    acks() catch break;
                    var busy = false;
                    for (slots) |s| if (s.busy and !s.discarded) {
                        busy = true;
                    };
                    if (!busy) break;
                    const delay: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
                    _ = linux.nanosleep(&delay, null);
                }
                _ = c.close(socket);
                socket = -1;
            }
            log("stop sent={d} released={d} dropped={d}", .{ sent, released, dropped });
            // Device teardown follows immediately. Imported DMA-BUFs retain their kernel
            // allocations, but no slot can be reused once this connection is closed.
            _ = D("vkDeviceWaitIdle")(dev);
            for (&slots) |*s| {
                if (s.dma >= 0) _ = c.close(s.dma);
                if (s.ready != null) D("vkDestroySemaphore")(dev, s.ready, null);

                if (s.fence != null) D("vkDestroyFence")(dev, s.fence, null);
                if (s.pool != null) D("vkDestroyCommandPool")(dev, s.pool, null);
                if (s.image != null) D("vkDestroyImage")(dev, s.image, null);
                if (s.memory != null) D("vkFreeMemory")(dev, s.memory, null);
                s.* = .{};
            }
            for (&completions) |*entry| {
                if (entry.semaphore != null) D("vkDestroySemaphore")(dev, entry.semaphore, null);
                entry.* = .{};
            }
        }
    };
}
