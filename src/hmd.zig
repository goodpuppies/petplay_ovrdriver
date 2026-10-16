//! Opt-in fictional HMD and a separate clocked display-redirect sink.
const std = @import("std");
const abi = @import("abi.zig");
const sink = @import("virtual_display.zig");
const direct = @import("direct.zig");
const linux = std.os.linux;
pub var enabled = std.atomic.Value(bool).init(false);
pub var active = std.atomic.Value(bool).init(false);
pub var failed = std.atomic.Value(bool).init(false);
pub var pose_updates = std.atomic.Value(u64).init(0);
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
        (!direct.enabled.load(.acquire) and !h.vtable.trackedDeviceAdded(h, "PETPLAY-SYNTHETIC-DISPLAY-001", 5, &redirect_device))) failed.store(true, .release);
}
pub fn stop() void {
    deactivate(&device);
    direct.cleanup();
    host = null;
    properties = null;
    enabled.store(false, .release);
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
        setProperty(f32, 2002, 1, 75) and setProperty(f32, 2001, 1, 0.002) and
        setProperty(f32, 2003, 1, 0.064) and setProperty(f32, 2026, 1, 0) and
        setProperty(u64, 2004, 3, 0x505054455354) and setProperty(bool, 2007, 4, true) and
        setProperty(bool, 2044, 4, true) and setProperty(bool, 1025, 4, false) and
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
    while (!stop_requested.load(.acquire)) {
        const pose = getPose(&device);
        host.?.vtable.trackedDevicePoseUpdated(host.?, index, &pose, @sizeOf(abi.Pose));
        _ = pose_updates.fetchAdd(1, .monotonic);
        const now = sink.nowNs();
        if (now == 0) {
            failed.store(true, .release);
            return;
        }
        // Absolute monotonic grid; missed slots are skipped rather than burst-replayed.
        const next = epoch_ns + ((now -| epoch_ns) / 4_000_000 + 1) * 4_000_000;
        const deadline: linux.timespec = .{ .sec = @intCast(next / 1_000_000_000), .nsec = @intCast(next % 1_000_000_000) };
        while (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &deadline, null)) == .INTR) {}
    }
}
fn getPose(_: *abi.Device) callconv(.c) abi.Pose {
    return .{ .vecPosition = .{ 0, 1.6, 0 } };
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
    w.* = 1280;
    h.* = 720;
}
fn onDesktop(_: *abi.Display) callconv(.c) bool {
    return !direct.enabled.load(.acquire);
}
fn realDisplay(_: *abi.Display) callconv(.c) bool {
    return false;
}
fn renderSize(_: *abi.Display, w: *u32, h: *u32) callconv(.c) void {
    w.* = 640;
    h.* = 640;
}
fn viewport(_: *abi.Display, eye: i32, x: *u32, y: *u32, w: *u32, h: *u32) callconv(.c) void {
    x.* = if (eye == 0) 0 else 640;
    y.* = 0;
    w.* = 640;
    h.* = 720;
}
fn projection(_: *abi.Display, _: i32, l: *f32, r: *f32, t: *f32, b: *f32) callconv(.c) void {
    l.* = -1;
    r.* = 1;
    t.* = -1;
    b.* = 1;
}
fn distortion(_: *abi.Display, _: i32, u: f32, v: f32) callconv(.c) abi.Distortion {
    return .{ .red = .{ u, v }, .green = .{ u, v }, .blue = .{ u, v } };
}
fn inverse(_: *abi.Display, result: *abi.Vector2, _: i32, channel: u32, u: f32, v: f32) callconv(.c) bool {
    if (channel > 2) return false;
    result.* = .{ .v = .{ u, v } };
    return true;
}
