//! Opt-in Linux driver-direct diagnostic. Real runtime-allocated images; `captureFrame` reads them back for the lab.
//! ALVR is an architectural reference, not a linked dependency or copied implementation.
const std = @import("std");
const abi = @import("abi.zig");
const clock = @import("virtual_display.zig");
const linux = std.os.linux;
const profile = @import("display_profile.zig");
const fence_probe = @import("fence_probe.zig");
const reader = @import("direct_reader.zig");
const sem_probe = @import("semaphore_probe.zig");
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
var watch_env_parsed = false;
var watch_env_presents: u32 = 0;
var fence_budget: u32 = 0;
var watch_budget: u32 = 0;
/// Retained resource-manager handle for the semaphore being watched, 0 when idle.
var watch_handle: u64 = 0;
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
/// Every layer of the frame being submitted and of the last presented one, for `captureFrame`.
const max_layers = 8;
const FrameLayer = struct { textures: [2]u64 = @splat(0), bounds: [2][4]f32 = @splat(@splat(0)) };
var building: [max_layers]FrameLayer = @splat(.{});
var presented: [max_layers]FrameLayer = @splat(.{});
var presented_count: u32 = 0;
var stats: Stats = .{};
/// One `NewSharedVulkanSemaphore` attempt and its export, for the completion-contract probe.
pub const SemaphoreProbe = struct {
    created: bool = false,
    handle: u64 = 0,
    refOk: bool = false,
    fdOk: bool = false,
    released: bool = false,
};
/// Counter readings from a runtime-allocated timeline semaphore across Present callbacks.
/// `advances` is the only field that distinguishes a real completion signal from a dead one.
pub const SemaphoreWatch = struct {
    importOk: bool = false,
    samples: u64 = 0,
    advances: u64 = 0,
    readFailures: u64 = 0,
    first: u64 = 0,
    last: u64 = 0,
    max: u64 = 0,
};
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
    semaphoreProbeRuns: u64 = 0,
    semaphoreCounting: SemaphoreProbe = .{},
    semaphoreBinary: SemaphoreProbe = .{},
    semaphoreWatch: SemaphoreWatch = .{},
};
pub fn requestFenceProbe() bool {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!enabled.load(.acquire)) return false;
    fence_budget = 64;
    return true;
}
/// Asks the runtime's resource manager for a shared Vulkan semaphore and exports it, which is
/// the first half of a real cross-process completion contract. Allocating one does not oblige
/// SteamVR to signal it; this establishes only whether the primitive is obtainable at all.
fn probeOne(r: *abi.Resources, counting: bool, out: *SemaphoreProbe) void {
    out.* = .{};
    if (!r.vtable.semaphore(r, counting, &out.handle) or out.handle == 0) {
        log("PetPlay semaphore probe: NewSharedVulkanSemaphore(counting={}) refused", .{counting});
        return;
    }
    out.created = true;
    var ipc: u64 = 0;
    out.refOk = r.vtable.ref(r, out.handle, &ipc);
    if (out.refOk) {
        var fd: i32 = -1;
        out.fdOk = r.vtable.receiveFd(r, ipc, &fd) and fd >= 0;
        if (fd >= 0) _ = linux.close(fd);
    }
    // Release immediately: this probe establishes availability, it does not retain a resource.
    out.released = r.vtable.unref(r, out.handle);
    if (!out.released) stats.releaseFailures += 1;
    log("PetPlay semaphore probe: counting={} handle={x} ref={} fd={} released={}", .{ counting, out.handle, out.refOk, out.fdOk, out.released });
}
pub fn requestSemaphoreProbe() bool {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!enabled.load(.acquire)) return false;
    const r = manager() orelse return false;
    stats.semaphoreProbeRuns += 1;
    probeOne(r, true, &stats.semaphoreCounting);
    probeOne(r, false, &stats.semaphoreBinary);
    startWatch(r, if (watchPresetPresents() > 0) watchPresetPresents() else 300);
    return true;
}
/// Retains one counting semaphore, imports its payload and samples it for a bounded number of
/// Present callbacks. Caller holds `mutex`.
fn watchPresetPresents() u32 {
    if (!watch_env_parsed) {
        watch_env_parsed = true;
        if (getenv("PP_SEMAPHORE_WATCH_PRESENTS")) |text| {
            watch_env_presents = std.fmt.parseInt(u32, std.mem.span(text), 10) catch 0;
            if (watch_env_presents > 4000) watch_env_presents = 4000;
        }
    }
    return watch_env_presents;
}
fn startWatch(r: *abi.Resources, presents: u32) void {
    if (watch_handle != 0 or presents == 0) return;
    var handle: u64 = 0;
    if (!r.vtable.semaphore(r, true, &handle) or handle == 0) return;
    var ipc: u64 = 0;
    var fd: i32 = -1;
    if (!r.vtable.ref(r, handle, &ipc) or !r.vtable.receiveFd(r, ipc, &fd) or fd < 0) {
        if (fd >= 0) _ = linux.close(fd);
        if (!r.vtable.unref(r, handle)) stats.releaseFailures += 1;
        log("PetPlay semaphore watch: export failed", .{});
        return;
    }
    sem_probe.start(fd) catch |err| {
        log("PetPlay semaphore watch: import failed: {s}", .{@errorName(err)});
        if (!r.vtable.unref(r, handle)) stats.releaseFailures += 1;
        return;
    };
    watch_handle = handle;
    watch_budget = presents;
    stats.semaphoreWatch = .{ .importOk = true };
    if (sem_probe.sample()) |value| {
        stats.semaphoreWatch.first = value;
        stats.semaphoreWatch.last = value;
        stats.semaphoreWatch.max = value;
    }
    log("PetPlay semaphore watch: imported handle={x}, sampling {d} presents", .{ handle, watch_budget });
}
/// Caller holds `mutex`.
fn stopWatch() void {
    if (watch_handle == 0) return;
    sem_probe.stop();
    if (resources) |r| if (!r.vtable.unref(r, watch_handle)) {
        stats.releaseFailures += 1;
    };
    watch_handle = 0;
    watch_budget = 0;
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
    stopWatch();
    sem_probe.deinit();
    for (&sets) |*set| release(set);
    presented_count = 0;
    reader.deinit();
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
    return epoch + profile.tickOffsetNs(n);
}
fn announceLoop() void {
    var n: u64 = 1;
    while (!exit.load(.acquire)) {
        // Independent rational profile-frequency grid. Announce at a fixed 2 ms running-start lead;
        // this is the synthetic display's clock, not an overlay submission phase guess.
        const announce = tickNs(n) - 2_000_000;
        sleepUntil(announce);
        if (exit.load(.acquire)) break;
        const now = clock.nowNs();
        const offset = (@as(f64, @floatFromInt(announce)) - @as(f64, @floatFromInt(now))) / 1e9;
        host.?.vtable.vsyncEvent(host.?, offset);
        n = @max(n + 1, profile.frameAt(clock.nowNs() -| epoch) + 1);
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
    if (!enabled.load(.acquire) or desc.width == 0 or desc.height == 0 or desc.width > 8192 or desc.height > 8192 or
        desc.samples != 1 or (desc.format != 37 and desc.format != 43 and desc.format != 44 and desc.format != 50))
    {
        stats.allocationFailures += 1;
        log("PetPlay direct rejected allocation pid={d} {d}x{d} format={d} samples={d}", .{ pid, desc.width, desc.height, desc.format, desc.samples });
        return;
    }
    const bytes = @as(u64, desc.width) * desc.height * 4 * 3;
    if (stats.liveBytes + bytes > @as(u64, profile.current.maxSwapchainMiB) * 1024 * 1024) {
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
    if (layers_in_frame <= max_layers) building[layers_in_frame - 1] = .{ .textures = .{ eyes[0].texture, eyes[1].texture }, .bounds = .{ eyes[0].bounds, eyes[1].bounds } };
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
    presented = building;
    presented_count = @min(layers_in_frame, max_layers);
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
    if (watch_handle == 0 and stats.presentCalls == 1 and watchPresetPresents() > 0) {
        if (manager()) |r| startWatch(r, watchPresetPresents());
    }
    if (watch_budget > 0) {
        watch_budget -= 1;
        if (sem_probe.sample()) |value| {
            const w = &stats.semaphoreWatch;
            w.samples += 1;
            if (w.samples == 1) w.first = value;
            if (value != w.last) w.advances += 1;
            w.last = value;
            w.max = @max(w.max, value);
        } else stats.semaphoreWatch.readFailures += 1;
        const w = stats.semaphoreWatch;
        if (w.samples % 75 == 0 and w.samples > 0) log("PetPlay semaphore watch progress: samples={d} advances={d} last={d} presents={d}", .{ w.samples, w.advances, w.last, stats.presentCalls });
        if (watch_budget == 0) log("PetPlay semaphore watch complete: samples={d} advances={d} first={d} last={d} readFailures={d}", .{ stats.semaphoreWatch.samples, stats.semaphoreWatch.advances, stats.semaphoreWatch.first, stats.semaphoreWatch.last, stats.semaphoreWatch.readFailures });
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
    const n: u64 = profile.frameAt(clock.nowNs() -| epoch) + 1 + extra;
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

fn presentCount() u64 {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    return stats.presentCalls;
}
pub const CapturedEye = struct { file: []const u8, width: u32, height: u32, format: u32, bounds: [4]f32 };
pub const Capture = struct { present: u64, layers: []const [2]CapturedEye };

/// Reads every layer of the next presented frame into `<directory>/<present>-<texture>.rgba`
/// (width × height × 4 bytes in the image's channel order), layers in submission order.
/// Like ALVR, it takes the frame at Present and then waits a short guard for its writes.
pub fn captureFrame(a: std.mem.Allocator, directory: []const u8) !Capture {
    if (!enabled.load(.acquire)) return error.DriverDirectDisabled;
    const path = try a.dupeZ(u8, directory);
    const raw_dir = linux.openat(linux.AT.FDCWD, path, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(raw_dir) != .SUCCESS) return error.CaptureDirectoryUnavailable;
    const dir: i32 = @intCast(raw_dir);
    defer _ = linux.close(dir);

    const start = presentCount();
    const deadline = clock.nowNs() + 500_000_000;
    while (presentCount() == start) {
        if (clock.nowNs() > deadline) return error.NoPresent;
        sleepUntil(clock.nowNs() + 1_000_000);
    }
    sleepUntil(clock.nowNs() + 4_000_000);

    const Pending = struct { texture: u64, source: ?reader.Source, bounds: [4]f32, desc: abi.SwapDesc };
    var pending: [max_layers][2]Pending = undefined;
    var count: usize = 0;
    var frame: u64 = 0;
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        frame = stats.presentCalls;
        count = presented_count;
        for (presented[0..count], 0..) |layer, l| for (layer.textures, 0..) |texture, e| {
            pending[l][e] = .{ .texture = texture, .source = null, .bounds = layer.bounds[e], .desc = .{ .width = 0, .height = 0, .format = 0, .samples = 0 } };
            const set = find(texture) orelse continue;
            for (set.handles, 0..) |h, i| if (h == texture) {
                const dup = linux.fcntl(set.fds[i], linux.F.DUPFD_CLOEXEC, 0);
                if (linux.errno(dup) != .SUCCESS) break;
                pending[l][e].source = .{ .fd = @intCast(dup), .width = set.desc.width, .height = set.desc.height, .format = set.desc.format };
                pending[l][e].desc = set.desc;
                break;
            };
        };
    }
    defer for (pending[0..count]) |layer| for (layer) |eye| if (eye.source) |s| {
        if (s.fd >= 0) _ = linux.close(s.fd);
    };

    const layers = try a.alloc([2]CapturedEye, count);
    for (pending[0..count], 0..) |*layer, l| for (layer, 0..) |*eye, e| {
        const name = try std.fmt.allocPrint(a, "{d}-{x}.rgba", .{ frame, eye.texture });
        layers[l][e] = .{ .file = name, .width = eye.desc.width, .height = eye.desc.height, .format = eye.desc.format, .bounds = eye.bounds };
        // Both eyes may share one texture (side by side, split by bounds): read it once.
        if (e == 1 and layer[0].texture == eye.texture) continue;
        const source = eye.source orelse return error.UnknownTexture;
        eye.source = null; // read() consumes the duplicate fd.
        const pixels = try a.alloc(u8, @as(usize, source.width) * source.height * 4);
        try reader.read(source, pixels);
        const raw = linux.openat(dir, try a.dupeZ(u8, name), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(raw) != .SUCCESS) return error.OutputExistsOrUnavailable;
        const fd: i32 = @intCast(raw);
        defer _ = linux.close(fd);
        var offset: usize = 0;
        while (offset < pixels.len) {
            const n = linux.write(fd, pixels[offset..].ptr, pixels.len - offset);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailure;
            offset += n;
        }
    };
    return .{ .present = frame, .layers = layers };
}

/// Read just the selected presented layer/eye, GPU-scaled before crossing into host memory.
pub fn captureEye(a: std.mem.Allocator, directory: []const u8, layer_index: usize, eye_index: usize, max_edge: u32) !struct { present: u64, eye: CapturedEye } {
    if (!enabled.load(.acquire)) return error.DriverDirectDisabled;
    const raw_dir = linux.openat(linux.AT.FDCWD, try a.dupeZ(u8, directory), .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(raw_dir) != .SUCCESS) return error.CaptureDirectoryUnavailable;
    const dir: i32 = @intCast(raw_dir);
    defer _ = linux.close(dir);
    const start = presentCount();
    const deadline = clock.nowNs() + 500_000_000;
    while (presentCount() == start) {
        if (clock.nowNs() > deadline) return error.NoPresent;
        sleepUntil(clock.nowNs() + 1_000_000);
    }
    sleepUntil(clock.nowNs() + 4_000_000);
    var source: reader.Source = undefined;
    var bounds: [4]f32 = undefined;
    var texture: u64 = 0;
    var frame: u64 = 0;
    {
        std.Io.Threaded.mutexLock(&mutex);
        defer std.Io.Threaded.mutexUnlock(&mutex);
        if (layer_index >= presented_count or eye_index > 1) return error.InvalidEyeSelection;
        frame = stats.presentCalls;
        texture = presented[layer_index].textures[eye_index];
        bounds = presented[layer_index].bounds[eye_index];
        const set = find(texture) orelse return error.UnknownTexture;
        var found = false;
        for (set.handles, 0..) |h, i| if (h == texture) {
            const dup = linux.fcntl(set.fds[i], linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(dup) != .SUCCESS) return error.DupFailed;
            source = .{ .fd = @intCast(dup), .width = set.desc.width, .height = set.desc.height, .format = set.desc.format };
            found = true;
            break;
        };
        if (!found) return error.UnknownTexture;
    }
    var owned = true;
    defer if (owned) {
        _ = linux.close(source.fd);
    };
    if (source.width == 0 or source.height == 0) return error.InvalidImageSize;
    const edge = @max(source.width, source.height);
    const width = @max(1, @as(u32, @intCast(@as(u64, source.width) * @min(edge, max_edge) / edge)));
    const height = @max(1, @as(u32, @intCast(@as(u64, source.height) * @min(edge, max_edge) / edge)));
    const pixels = try a.alloc(u8, @as(usize, width) * height * 4);
    owned = false;
    try reader.readScaled(source, pixels, width, height);
    const name = try std.fmt.allocPrint(a, "{d}-{x}-eye.rgba", .{ frame, texture });
    const raw = linux.openat(dir, try a.dupeZ(u8, name), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(raw) != .SUCCESS) return error.OutputExistsOrUnavailable;
    const fd: i32 = @intCast(raw);
    defer _ = linux.close(fd);
    var offset: usize = 0;
    while (offset < pixels.len) {
        const n = linux.write(fd, pixels[offset..].ptr, pixels.len - offset);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailure;
        offset += n;
    }
    return .{ .present = frame, .eye = .{ .file = name, .width = width, .height = height, .format = source.format, .bounds = bounds } };
}
