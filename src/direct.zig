//! Opt-in Linux driver-direct diagnostic. Real runtime-allocated images; no GPU reader yet.
//! ALVR is an architectural reference, not a linked dependency or copied implementation.
const std = @import("std");
const abi = @import("abi.zig");
const clock = @import("virtual_display.zig");
const linux = std.os.linux;
const fence_probe = @import("fence_probe.zig");
var fence_budget: u32 = 0;
pub var enabled = std.atomic.Value(bool).init(false);
var ctx: ?*abi.Context = null;
var host: ?*abi.Host = null;
var logger: ?*abi.DriverLog = null;
var resources: ?*abi.Resources = null;
var mutex: std.Io.Mutex = .init;
var exit = std.atomic.Value(bool).init(true);
var announcer: ?std.Thread = null;
var epoch: u64 = 0;
const max_sets = 64;
const Set = struct {
    pid: u32 = 0,
    desc: abi.SwapDesc = .{ .width = 0, .height = 0, .format = 0, .samples = 0 },
    handles: [3]u64 = @splat(0),
    fds: [3]i32 = @splat(-1),
    next: u32 = 0,
};
var sets: [max_sets]Set = @splat(.{});
var layers_in_frame: u32 = 0;
var stats: Stats = .{};
pub const Stats = struct {
    createCalls: u64 = 0,
    allocatedSets: u64 = 0,
    liveSets: u64 = 0,
    allocationFailures: u64 = 0,
    liveBytes: u64 = 0,
    resourceUnavailable: u64 = 0,
    releaseFailures: u64 = 0,
    exportedFds: u64 = 0,
    submitCalls: u64 = 0,
    presentCalls: u64 = 0,
    postPresentCalls: u64 = 0,
    timingCalls: u64 = 0,
    nextCalls: u64 = 0,
    unknownTextures: u64 = 0,
    lastLayerCount: u32 = 0,
    maxLayerCount: u32 = 0,
    lastSyncTexture: u64 = 0,
    lastEyes: [2]u64 = @splat(0),
    lastInodes: [2]u64 = @splat(0),
    fenceSamples: u64 = 0,
    fenceActiveSamples: u64 = 0,
    fenceFailedSamples: u64 = 0,
    fenceSampleNs: u64 = 0,
    lastFences: [2]fence_probe.Result = @splat(.{}),
};
pub fn requestFenceProbe() bool {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!enabled.load(.acquire)) return false;
    fence_budget = 64;
    return true;
}
pub fn snapshot() Stats {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    var result = stats;
    for (result.lastEyes, 0..) |handle, eye| {
        if (find(handle)) |set| for (set.handles, 0..) |h, i| {
            if (h != handle) continue;
            var stat: linux.Statx = undefined;
            if (linux.errno(linux.statx(set.fds[i], "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stat)) == .SUCCESS and stat.mask.INO) result.lastInodes[eye] = stat.ino;
            break;
        };
    }
    return result;
}
fn log(comptime fmt: []const u8, args: anytype) void {
    if (logger) |l| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
        l.vtable.log(l, msg);
    }
}
pub fn configure(context: *abi.Context, h: *abi.Host, opt_in: bool) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    ctx = context;
    host = h;
    enabled.store(opt_in, .release);
    stats = .{};
    layers_in_frame = 0;
    fence_budget = 0;
    var err: i32 = 0;
    const raw = context.vtable.getGenericInterface(context, abi.log_version, &err);
    logger = if (err == 0 and raw != null) @ptrCast(@alignCast(raw.?)) else null;
    if (opt_in) log("PetPlay driver-direct selected (image consumption disabled)", .{});
}
pub fn startClock() bool {
    if (!enabled.load(.acquire)) return true;
    epoch = clock.nowNs();
    if (epoch == 0 or announcer != null) return false;
    exit.store(false, .release);
    announcer = std.Thread.spawn(.{}, announceLoop, .{}) catch {
        exit.store(true, .release);
        return false;
    };
    return true;
}
pub fn stopClock() void {
    exit.store(true, .release);
    if (announcer) |t| t.join();
    announcer = null;
}
pub fn cleanup() void {
    stopClock();
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    for (&sets) |*set| release(set);
    log("PetPlay direct cleanup: creates={d} allocated={d} failures={d} unavailable={d} submits={d} presents={d} posts={d} layers={d} unknown={d} releaseFailures={d}", .{ stats.createCalls, stats.allocatedSets, stats.allocationFailures, stats.resourceUnavailable, stats.submitCalls, stats.presentCalls, stats.postPresentCalls, stats.maxLayerCount, stats.unknownTextures, stats.releaseFailures });
    resources = null;
    ctx = null;
    host = null;
    logger = null;
    enabled.store(false, .release);
}
fn sleepUntil(ns: u64) void {
    const t: linux.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    while (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &t, null)) == .INTR) {}
}
fn tickNs(n: u64) u64 {
    return epoch + @as(u64, @intCast((@as(u128, n) * 1_000_000_000 + 74) / 75));
}
fn announceLoop() void {
    var n: u64 = 1;
    while (!exit.load(.acquire)) {
        // Independent rational 75 Hz grid. Announce at a fixed 2 ms running-start lead;
        // this is the synthetic display's clock, not an overlay submission phase guess.
        const announce = tickNs(n) - 2_000_000;
        sleepUntil(announce);
        if (exit.load(.acquire)) break;
        const now = clock.nowNs();
        const offset = (@as(f64, @floatFromInt(announce)) - @as(f64, @floatFromInt(now))) / 1e9;
        host.?.vtable.vsyncEvent(host.?, offset);
        n = @max(n + 1, @as(u64, @intCast(@as(u128, clock.nowNs() -| epoch) * 75 / 1_000_000_000)) + 1);
    }
}
pub var object: abi.Direct = .{ .vtable = &table.methods };
const table: abi.Table(abi.DirectMethods) = .{ .methods = .{ .create = create, .destroy = destroy, .destroyAll = destroyAll, .next = next, .submit = submit, .present = present, .post = post, .timing = timing } };
fn manager() ?*abi.Resources {
    if (resources) |r| return r;
    const c = ctx orelse return null;
    // The SDK notes asynchronous initialization: retry on the next allocation, do not
    // cache a failed lookup in provider Init and do not call through a null interface.
    var err: i32 = 0;
    const raw = c.vtable.getGenericInterface(c, abi.resource_version, &err);
    if (err != 0 or raw == null) {
        stats.resourceUnavailable += 1;
        return null;
    }
    resources = @ptrCast(@alignCast(raw.?));
    return resources;
}
fn release(set: *Set) void {
    const live = set.handles[0] != 0;
    for (set.fds) |fd| if (fd >= 0) {
        _ = linux.close(fd);
    };
    if (resources) |r| for (set.handles) |handle| {
        if (handle != 0 and !r.vtable.unref(r, handle)) stats.releaseFailures += 1;
    };
    if (live) stats.liveBytes -|= @as(u64, set.desc.width) * set.desc.height * 4 * 3;
    set.* = .{};
    if (live) stats.liveSets -|= 1;
}
fn create(_: *abi.Direct, pid: u32, desc: *const abi.SwapDesc, out: *abi.SwapSet) callconv(.c) void {
    out.* = .{};
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    stats.createCalls += 1;
    // Bound allocation and support only single-sample 8-bit RGBA/BGRA lab images.
    if (!enabled.load(.acquire) or desc.width == 0 or desc.height == 0 or desc.width > 4096 or desc.height > 4096 or
        desc.samples != 1 or (desc.format != 37 and desc.format != 43 and desc.format != 44 and desc.format != 50))
    {
        stats.allocationFailures += 1;
        log("PetPlay direct rejected allocation pid={d} {d}x{d} format={d} samples={d}", .{ pid, desc.width, desc.height, desc.format, desc.samples });
        return;
    }
    const bytes = @as(u64, desc.width) * desc.height * 4 * 3;
    if (stats.liveBytes + bytes > 512 * 1024 * 1024) {
        stats.allocationFailures += 1;
        return;
    }
    var slot: ?*Set = null;
    for (&sets) |*s| if (s.handles[0] == 0) {
        slot = s;
        break;
    };
    const r = manager();
    if (slot == null or r == null) {
        stats.allocationFailures += 1;
        return;
    }
    // Keep partial work separate: failures must never expose a partly initialized set.
    var pending: Set = .{ .pid = pid, .desc = desc.* };
    for (0..3) |i| {
        // VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, TRANSFER_SRC | SAMPLED | INPUT_ATTACHMENT.
        if (!r.?.vtable.image(r.?, desc.format, desc.width, desc.height, true, false, true, 1, 1, 8, 0x85, &pending.handles[i]) or pending.handles[i] == 0) {
            releasePartial(&pending);
            stats.allocationFailures += 1;
            return;
        }
        var ipc: u64 = 0;
        if (!r.?.vtable.ref(r.?, pending.handles[i], &ipc) or !r.?.vtable.receiveFd(r.?, ipc, &pending.fds[i]) or pending.fds[i] < 0) {
            releasePartial(&pending);
            stats.allocationFailures += 1;
            return;
        }
        if (linux.errno(linux.fcntl(pending.fds[i], linux.F.SETFD, linux.FD_CLOEXEC)) != .SUCCESS) {
            releasePartial(&pending);
            stats.allocationFailures += 1;
            return;
        }
        stats.exportedFds += 1;
    }
    slot.?.* = pending;
    out.handles = pending.handles;
    stats.allocatedSets += 1;
    stats.liveSets += 1;
    stats.liveBytes += bytes;
    log("PetPlay direct allocated pid={d} {d}x{d} format={d} handles={x},{x},{x}", .{ pid, desc.width, desc.height, desc.format, pending.handles[0], pending.handles[1], pending.handles[2] });
}
fn releasePartial(set: *Set) void {
    // release() normally removes a published set from the live count.
    const live = stats.liveSets;
    const bytes = stats.liveBytes;
    release(set);
    stats.liveSets = live;
    stats.liveBytes = bytes;
}
fn find(handle: u64) ?*Set {
    if (handle == 0) return null;
    for (&sets) |*s| for (s.handles) |h| if (h == handle) return s;
    return null;
}
fn destroy(_: *abi.Direct, handle: u64) callconv(.c) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (find(handle)) |s| release(s);
}
fn destroyAll(_: *abi.Direct, pid: u32) callconv(.c) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    for (&sets) |*s| if (s.handles[0] != 0 and s.pid == pid) {
        release(s);
    };
}
fn next(_: *abi.Direct, handles: *const [2]u64, indices: *[2]u32) callconv(.c) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    stats.nextCalls += 1;
    // Both eyes may refer to the same set: rotate it only once for this call.
    const left = find(handles[0]);
    const right = find(handles[1]);
    if (left) |s| {
        s.next = (s.next + 1) % 3;
        indices[0] = s.next;
    } else indices[0] = 0;
    if (right) |s| {
        if (right != left) s.next = (s.next + 1) % 3;
        indices[1] = s.next;
    } else indices[1] = 0;
}
fn submit(_: *abi.Direct, eyes: *const [2]abi.LayerEye) callconv(.c) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    stats.submitCalls += 1;
    layers_in_frame +|= 1;
    stats.lastEyes = .{ eyes[0].texture, eyes[1].texture };
    for (eyes) |eye| if (find(eye.texture) == null) {
        stats.unknownTextures += 1;
    };
    if (stats.submitCalls <= 8) log("PetPlay direct layer={d} textures={x},{x} boundsLeft={any} prediction={d}", .{ layers_in_frame, eyes[0].texture, eyes[1].texture, eyes[0].bounds, eyes[0].prediction });
}
fn present(_: *abi.Direct, sync: u64) callconv(.c) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    stats.presentCalls += 1;
    stats.lastLayerCount = layers_in_frame;
    stats.maxLayerCount = @max(stats.maxLayerCount, layers_in_frame);
    stats.lastSyncTexture = sync;
    layers_in_frame = 0;
    if (fence_budget > 0) {
        fence_budget -= 1;
        stats.fenceSampleNs = clock.nowNs();
        for (stats.lastEyes, 0..) |handle, eye| {
            if (find(handle)) |set| for (set.handles, 0..) |h, i| {
                if (h != handle) continue;
                const f = fence_probe.inspect(set.fds[i]);
                stats.lastFences[eye] = f;
                stats.fenceSamples += 1;
                if (f.active > 0) stats.fenceActiveSamples += 1;
                if (f.exportErrno != 0 or f.infoErrno != 0 or f.errors > 0) stats.fenceFailedSamples += 1;
                if (fence_budget == 63 or fence_budget == 0) log("PetPlay writer fence eye={d} count={d} active={d} name={s} driver={s} stamp={d} sampled={d} exportErr={d} infoErr={d}", .{ eye, f.count, f.active, std.mem.sliceTo(&f.firstName, 0), std.mem.sliceTo(&f.firstDriver, 0), f.newestTimestampNs, stats.fenceSampleNs, f.exportErrno, f.infoErrno });
                break;
            };
        }
    }
    if (stats.presentCalls == 1) log("PetPlay direct first Present: layers={d}, sync={x} (no GPU readback)", .{ stats.lastLayerCount, sync });
}
fn post(_: *abi.Direct, throttle: ?*const abi.Throttling) callconv(.c) void {
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        stats.postPresentCalls += 1;
    }
    if (exit.load(.acquire)) return;
    // Diagnostic backend advertises no app throttling support. Cap even unexpected hints.
    const extra: u64 = if (throttle) |t| @min(t.frames, 4) else 0;
    const n: u64 = @intCast(@as(u128, clock.nowNs() -| epoch) * 75 / 1_000_000_000 + 1 + extra);
    sleepUntil(tickNs(n));
}
fn timing(_: *abi.Direct, t: *abi.DirectTiming) callconv(.c) void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    stats.timingCalls += 1;
    if (t.size < @sizeOf(abi.DirectTiming)) return;
    t.presents = 1;
    t.mispresented = 0;
    t.dropped = 0;
    t.flags = 0;
}
