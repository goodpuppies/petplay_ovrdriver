//! Opt-in fictional HMD and a separate clocked display-redirect sink.
const std = @import("std");
const abi = @import("abi.zig");
const sink = @import("virtual_display.zig");
const direct = @import("direct.zig");
const linux = std.os.linux;
const profile = @import("display_profile.zig");
pub var enabled = std.atomic.Value(bool).init(false);
pub var active = std.atomic.Value(bool).init(false);
pub var failed = std.atomic.Value(bool).init(false);
pub var pose_updates = std.atomic.Value(u64).init(0);
/// A remote head (WebXR client, agent) replaces the fixed standing pose until cleared.
pub const HeldPose = struct {
    position: [3]f64,
    rotation: abi.Quaternion,
    velocity: [3]f64 = @splat(0),
    angularVelocity: [3]f64 = @splat(0),
    /// The client's own counter, echoed through the pose ring for latency measurement.
    sequence: u64 = 0,
    /// When the driver received it (CLOCK_MONOTONIC), recorded for latency breakdowns.
    held_ns: u64 = 0,
};
var ring: ?@import("pose_ring.zig").Ring = null;
/// Publishes held poses beside the control socket for the media worker. Optional.
pub fn attachPoseRing(directory_fd: i32) void {
    if (directory_fd < 0 or ring != null) return;
    ring = @import("pose_ring.zig").open(directory_fd, "hmd-poses") catch null;
    @import("controllers.zig").attachPoseRing(directory_fd);
}
var held_mutex: std.Io.Mutex = .init;
var held: ?HeldPose = null;
/// What SteamVR sees while the device runs: `held` copied once per display frame, just before
/// each display tick. Every frame the compositor renders therefore has exactly one head pose,
/// and the pose ring records it with its latch time for the media worker to tag frames with.
var latched: ?HeldPose = null;
pub var held_updates = std.atomic.Value(u64).init(0);
/// Holds the head at `pose`, or returns it to the fixed default when null.
pub fn hold(pose: ?HeldPose) !void {
    if (!enabled.load(.acquire)) return error.HmdDisabled;
    std.Io.Threaded.mutexLock(&held_mutex);
    defer std.Io.Threaded.mutexUnlock(&held_mutex);
    held = pose;
    if (held) |*h| h.held_ns = sink.nowNs();
    _ = held_updates.fetchAdd(1, .monotonic);
}
/// Publishes the newest held pose as the one SteamVR renders with. Called by the pose loop.
fn latch(now: u64) void {
    std.Io.Threaded.mutexLock(&held_mutex);
    defer std.Io.Threaded.mutexUnlock(&held_mutex);
    latched = held;
    if (held) |p| if (ring) |r| r.write(.{
        .time_ns = now,
        .client_sequence = p.sequence,
        .rotation = .{ @floatCast(p.rotation.x), @floatCast(p.rotation.y), @floatCast(p.rotation.z), @floatCast(p.rotation.w) },
        .position = .{ @floatCast(p.position[0]), @floatCast(p.position[1]), @floatCast(p.position[2]) },
        .held_ns = p.held_ns,
    });
}
/// The first display tick after `now`, on the same absolute CLOCK_MONOTONIC grid the headless
/// display layer uses: tick k is at ceil(k / hz) seconds.
fn nextTick(now: u64) u64 {
    const hz: u128 = profile.current.refreshHz;
    const k = @as(u128, now) * hz / 1_000_000_000 + 1;
    return @intCast((k * 1_000_000_000 + hz - 1) / hz);
}
pub fn isHeld() bool {
    std.Io.Threaded.mutexLock(&held_mutex);
    defer std.Io.Threaded.mutexUnlock(&held_mutex);
    return held != null;
}
var stop_requested = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;
var host: ?*abi.Host = null;
var properties: ?*abi.Properties = null;
var index: u32 = 0xffffffff;
var device: abi.Device = .{ .vtable = &device_table.methods };
var redirect_device: abi.Device = .{ .vtable = &redirect_table.methods };
var display: abi.Display = .{ .vtable = &display_table.methods };
const device_table: abi.Table(abi.DeviceMethods) = .{ .methods = .{
    .activate = activate,
    .deactivate = deactivate,
    .enterStandby = standby,
    .getComponent = component,
    .debugRequest = debugRequest,
    .getPose = getPose,
} };
const display_table: abi.Table(abi.DisplayMethods) = .{ .methods = .{
    .bounds = bounds,
    .onDesktop = onDesktop,
    .realDisplay = realDisplay,
    .renderSize = renderSize,
    .viewport = viewport,
    .projection = projection,
    .distortion = distortion,
    .inverse = inverse,
} };
const redirect_table: abi.Table(abi.DeviceMethods) = .{ .methods = .{
    .activate = activateRedirect,
    .deactivate = deactivateRedirect,
    .enterStandby = standby,
    .getComponent = redirectComponent,
    .debugRequest = debugRequest,
    .getPose = getPose,
} };
fn activateRedirect(_: *abi.Device, id: u32) callconv(.c) i32 {
    const p = properties orelse return abi.driver_failed;
    const latency: f32 = 0;
    var item: abi.PropertyWrite = .{ .prop = 2001, .buffer = &latency, .size = 4, .tag = 1 };
    if (p.vtable.writeBatch(p, p.vtable.container(p, id), @ptrCast(&item), 1) != 0 or item.err != 0) return abi.driver_failed;
    sink.reset();
    return 0;
}
fn deactivateRedirect(_: *abi.Device) callconv(.c) void {}
fn redirectComponent(_: *abi.Device, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    return if (std.mem.eql(u8, std.mem.span(name), abi.virtual_display_version)) &sink.object else null;
}
pub fn start(ctx: *abi.Context, h: *abi.Host) void {
    failed.store(false, .release);
    pose_updates.store(0, .monotonic);
    var err: i32 = 0;
    const raw = ctx.vtable.getGenericInterface(ctx, abi.settings_version, &err) orelse return;
    if (err != 0) return;
    const settings: *abi.Settings = @ptrCast(@alignCast(raw));
    const opt_in = settings.vtable.getBool(settings, "driver_petplay", "syntheticHmd", &err);
    if (err != 0 or !opt_in) return;
    profile.load(settings) catch {
        failed.store(true, .release);
        return;
    };
    enabled.store(true, .release);
    const props_raw = ctx.vtable.getGenericInterface(ctx, abi.properties_version, &err);
    if (err != 0 or props_raw == null) {
        failed.store(true, .release);
        return;
    }
    properties = @ptrCast(@alignCast(props_raw.?));
    host = h;
    err = 0;
    const use_direct = settings.vtable.getBool(settings, "driver_petplay", "driverDirect", &err);
    direct.configure(ctx, h, err == 0 and use_direct);
    if (!h.vtable.trackedDeviceAdded(h, "PETPLAY-SYNTHETIC-HMD-001", 1, &device) or
        (!direct.enabled.load(.acquire) and !profile.current.virtualDisplay and
            !h.vtable.trackedDeviceAdded(h, "PETPLAY-SYNTHETIC-DISPLAY-001", 5, &redirect_device))) failed.store(true, .release);
}
pub fn stop() void {
    deactivate(&device);
    direct.cleanup();
    host = null;
    properties = null;
    enabled.store(false, .release);
    std.Io.Threaded.mutexLock(&held_mutex);
    held = null;
    latched = null;
    std.Io.Threaded.mutexUnlock(&held_mutex);
}
fn setProperty(comptime T: type, prop: i32, tag: u32, value: T) bool {
    const p = properties orelse return false;
    var item: abi.PropertyWrite = .{ .prop = prop, .buffer = &value, .size = @sizeOf(T), .tag = tag };
    return p.vtable.writeBatch(p, p.vtable.container(p, index), @ptrCast(&item), 1) == 0 and item.err == 0;
}
fn stringProperty(prop: i32, value: [:0]const u8) bool {
    const p = properties orelse return false;
    var item: abi.PropertyWrite = .{ .prop = prop, .buffer = value.ptr, .size = @intCast(value.len + 1), .tag = 5 };
    return p.vtable.writeBatch(p, p.vtable.container(p, index), @ptrCast(&item), 1) == 0 and item.err == 0;
}
fn activate(_: *abi.Device, id: u32) callconv(.c) i32 {
    if (active.load(.acquire) or host == null or properties == null) return abi.driver_failed;
    index = id;
    const ok = stringProperty(1000, "petplay") and stringProperty(1001, "PetPlay Synthetic HMD") and
        stringProperty(1002, "PETPLAY-SYNTHETIC-HMD-001") and stringProperty(1005, "PetPlay") and
        setProperty(f32, 2002, 1, @floatFromInt(profile.current.refreshHz)) and setProperty(f32, 2001, 1, 0.002) and
        setProperty(f32, 2003, 1, profile.current.ipdMeters) and setProperty(f32, 2026, 1, 0) and
        setProperty(u64, 2004, 3, 0x505054455354) and
        // Debug mode makes the compositor publish only a recreating mirror swapchain and no
        // eye target (PRESENT-BOUNDARY.md). A virtual-display session instead claims to be a
        // real direct-mode panel and must therefore report EDID identifiers to match against.
        setProperty(bool, 2007, 4, !profile.current.virtualDisplay) and
        setProperty(bool, 2044, 4, !profile.current.virtualDisplay) and
        (!profile.current.virtualDisplay or
            (setProperty(i32, 2011, 2, profile.current.edidVid) and
                setProperty(i32, 2015, 2, profile.current.edidPid))) and
        setProperty(bool, 1025, 4, false) and
        setProperty(bool, 1027, 4, false);
    if (!ok) {
        failed.store(true, .release);
        return abi.driver_failed;
    }
    if (direct.enabled.load(.acquire) and
        (!setProperty(bool, 2043, 4, true) or !setProperty(bool, 2116, 4, true)))
    {
        failed.store(true, .release);
        return abi.driver_failed;
    }
    sink.reset();
    if (!direct.startClock()) return abi.driver_failed;
    stop_requested.store(false, .release);
    thread = std.Thread.spawn(.{}, poseLoop, .{}) catch {
        direct.stopClock();
        failed.store(true, .release);
        return abi.driver_failed;
    };
    active.store(true, .release);
    return 0;
}
fn deactivate(_: *abi.Device) callconv(.c) void {
    direct.stopClock();
    stop_requested.store(true, .release);
    if (thread) |t| t.join();
    thread = null;
    active.store(false, .release);
    index = 0xffffffff;
}
fn poseLoop() void {
    const epoch_ns = sink.nowNs();
    if (epoch_ns == 0) {
        failed.store(true, .release);
        return;
    }
    const lead: u64 = @as(u64, profile.current.poseLatchLeadUs) * 1000;
    var next_latch: u64 = 0;
    while (!stop_requested.load(.acquire)) {
        const before = sink.nowNs();
        // Latch on time, then push immediately, so the new pose reaches vrserver before the
        // tick rather than up to one heartbeat later.
        if (before >= next_latch) {
            latch(before);
            @import("controllers.zig").latchAndPublish();
            next_latch = nextTick(before + lead) - lead;
        }
        const pose = getPose(&device);
        host.?.vtable.trackedDevicePoseUpdated(host.?, index, &pose, @sizeOf(abi.Pose));
        _ = pose_updates.fetchAdd(1, .monotonic);
        const now = sink.nowNs();
        if (now == 0) {
            failed.store(true, .release);
            return;
        }
        // A 4 ms heartbeat grid, interrupted by the next latch; missed slots are skipped.
        const heartbeat = epoch_ns + ((now -| epoch_ns) / 4_000_000 + 1) * 4_000_000;
        const next = @min(heartbeat, next_latch);
        const deadline: linux.timespec = .{ .sec = @intCast(next / 1_000_000_000), .nsec = @intCast(next % 1_000_000_000) };
        while (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &deadline, null)) == .INTR) {}
    }
}
fn getPose(_: *abi.Device) callconv(.c) abi.Pose {
    std.Io.Threaded.mutexLock(&held_mutex);
    defer std.Io.Threaded.mutexUnlock(&held_mutex);
    // A running device shows the latched pose; before the loop starts, the held one.
    const pose = (if (active.load(.acquire)) latched else held) orelse return .{ .vecPosition = .{ 0, 1.6, 0 } };
    return .{
        .vecPosition = pose.position,
        .qRotation = pose.rotation,
        .vecVelocity = pose.velocity,
        .vecAngularVelocity = pose.angularVelocity,
    };
}
fn standby(_: *abi.Device) callconv(.c) void {}
fn component(_: *abi.Device, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    if (direct.enabled.load(.acquire) and std.mem.eql(u8, std.mem.span(name), abi.direct_version)) return &direct.object;
    if (std.mem.eql(u8, std.mem.span(name), abi.display_version) or std.mem.eql(u8, std.mem.span(name), abi.display_legacy_version)) return &display;
    return null;
}
fn debugRequest(_: *abi.Device, _: [*:0]const u8, out: [*]u8, size: u32) callconv(.c) void {
    if (size > 0) out[0] = 0;
}
fn bounds(_: *abi.Display, x: *i32, y: *i32, w: *u32, h: *u32) callconv(.c) void {
    x.* = 0;
    y.* = 0;
    w.* = profile.current.displayEyeWidth * 2;
    h.* = profile.current.displayEyeHeight;
}
fn onDesktop(_: *abi.Display) callconv(.c) bool {
    return !direct.enabled.load(.acquire) and !profile.current.virtualDisplay;
}
fn realDisplay(_: *abi.Display) callconv(.c) bool {
    return profile.current.virtualDisplay;
}
fn renderSize(_: *abi.Display, w: *u32, h: *u32) callconv(.c) void {
    w.* = profile.current.renderWidth;
    h.* = profile.current.renderHeight;
}
fn viewport(_: *abi.Display, eye: i32, x: *u32, y: *u32, w: *u32, h: *u32) callconv(.c) void {
    x.* = if (eye == 0) 0 else profile.current.displayEyeWidth;
    y.* = 0;
    w.* = profile.current.displayEyeWidth;
    h.* = profile.current.displayEyeHeight;
}
/// OpenVR raw tangents: left and top negative, where top is the downward edge. The right eye
/// mirrors the left horizontally.
fn projection(_: *abi.Display, eye: i32, l: *f32, r: *f32, t: *f32, b: *f32) callconv(.c) void {
    const tan = profile.current.eyeTangents(eye);
    l.* = tan.left;
    r.* = tan.right;
    t.* = tan.top;
    b.* = tan.bottom;
}
fn distortion(_: *abi.Display, _: i32, u: f32, v: f32) callconv(.c) abi.Distortion {
    return .{ .red = .{ u, v }, .green = .{ u, v }, .blue = .{ u, v } };
}
fn inverse(_: *abi.Display, result: *abi.Vector2, _: i32, channel: u32, u: f32, v: f32) callconv(.c) bool {
    if (channel > 2) return false;
    result.* = .{ .v = .{ u, v } };
    return true;
}

test "a held head pose replaces the fixed standing pose until cleared" {
    try std.testing.expectError(error.HmdDisabled, hold(null));
    enabled.store(true, .release);
    defer {
        held = null;
        enabled.store(false, .release);
    }
    try std.testing.expectEqual(@as(f64, 1.6), getPose(&device).vecPosition[1]);
    try hold(.{ .position = .{ 0.1, 1.7, -0.2 }, .rotation = .{ .w = 0.5, .x = 0.5, .y = 0.5, .z = 0.5 }, .velocity = .{ 0, 0, 1 } });
    const pose = getPose(&device);
    try std.testing.expect(isHeld());
    try std.testing.expectEqual(@as(f64, -0.2), pose.vecPosition[2]);
    try std.testing.expectEqual(@as(f64, 0.5), pose.qRotation.y);
    try std.testing.expectEqual(@as(f64, 1), pose.vecVelocity[2]);
    try hold(null);
    try std.testing.expectEqual(@as(f64, 1.6), getPose(&device).vecPosition[1]);
}

test "latching copies the held pose and ticks follow the display grid" {
    enabled.store(true, .release);
    active.store(true, .release);
    defer {
        held = null;
        latched = null;
        active.store(false, .release);
        enabled.store(false, .release);
    }
    try hold(.{ .position = .{ 0, 1.7, 0 }, .rotation = .{}, .sequence = 9 });
    // Held but not yet latched: SteamVR still sees the standing default.
    try std.testing.expectEqual(@as(f64, 1.6), getPose(&device).vecPosition[1]);
    latch(123);
    try std.testing.expectEqual(@as(f64, 1.7), getPose(&device).vecPosition[1]);
    profile.current.refreshHz = 72;
    defer profile.current = .{};
    // 72 Hz: tick 1 at 13888889 ns (rounded up), tick 72 at exactly one second.
    try std.testing.expectEqual(@as(u64, 13_888_889), nextTick(0));
    try std.testing.expectEqual(@as(u64, 1_000_000_000), nextTick(999_999_999));
    try std.testing.expectEqual(@as(u64, 1_013_888_889), nextTick(1_000_000_000));
}
