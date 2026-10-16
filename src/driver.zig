const std = @import("std");
const abi = @import("abi.zig");
const state = @import("state.zig");
const hmd = @import("hmd.zig");
const ipc = @import("ipc.zig");
pub var transport: ipc.Server = .{};
const actor_mod = @import("actor.zig");
var host: ?*abi.Host = null;
var actor: actor_mod.Actor = .{ .process_owner = "steamvr" };
var request_busy = std.atomic.Value(bool).init(false);
var provider: abi.Provider = .{ .vtable = &provider_table.methods };
var device: abi.Device = .{ .vtable = &device_table.methods };
const versions = [_:null]?[*:0]const u8{ abi.provider_version, abi.device_version, abi.host_version, abi.display_version, abi.virtual_display_version, abi.display_legacy_version, abi.plugin_version, abi.direct_version, abi.resource_version };
const provider_table: abi.Table(abi.ProviderMethods) = .{ .methods = .{
    .init = init,
    .cleanup = cleanup,
    .getInterfaceVersions = getVersions,
    .runFrame = runFrame,
    .shouldBlockStandbyMode = blockStandby,
    .enterStandby = enterStandby,
    .leaveStandby = leaveStandby,
} };
const device_table: abi.Table(abi.DeviceMethods) = .{ .methods = .{
    .activate = activate,
    .deactivate = deactivate,
    .enterStandby = deviceStandby,
    .getComponent = component,
    .debugRequest = debugRequest,
    .getPose = getPose,
} };
export fn HmdDriverFactory(name: ?[*:0]const u8, code: ?*i32) callconv(.c) ?*anyopaque {
    if (name) |n| if (std.mem.eql(u8, std.mem.span(n), abi.plugin_version)) {
        if (code) |c| c.* = 0;
        return &@import("compositor.zig").object;
    };
    if (name) |n| if (std.mem.eql(u8, std.mem.span(n), abi.provider_version)) {
        if (code) |c| c.* = 0;
        return &provider;
    };
    if (code) |c| c.* = abi.interface_not_found;
    return null;
}
fn init(_: *abi.Provider, context: ?*abi.Context) callconv(.c) i32 {
    if (state.initialized.load(.acquire)) return abi.driver_failed;
    const ctx = context orelse return abi.driver_failed;
    var err: i32 = 0;
    const raw = ctx.vtable.getGenericInterface(ctx, abi.host_version, &err);
    if (err != 0 or raw == null) return if (err != 0) err else abi.interface_not_found;
    host = @ptrCast(@alignCast(raw.?));
    state.handle.store(ctx.vtable.getDriverHandle(ctx), .release);
    state.ticks.store(0, .monotonic);
    state.standby.store(false, .release);
    state.initialized.store(true, .release);
    state.ipc_failed.store(false, .release);
    if (configureTransport(ctx)) {
        transport.start() catch {
            state.ipc_failed.store(true, .release);
        };
    } else state.ipc_failed.store(true, .release);
    hmd.start(ctx, host.?);
    if (!hmd.failed.load(.acquire)) @import("controllers.zig").start(ctx, host.?);
    return 0;
}
// Steam's container can have a private /run/user. An explicit shared-home path
// allows the host PetPlay process to attach without entering its mount namespace.
fn configureTransport(ctx: *abi.Context) bool {
    var err: i32 = 0;
    const raw = ctx.vtable.getGenericInterface(ctx, abi.settings_version, &err) orelse return true;
    if (err != 0) return true;
    const settings: *abi.Settings = @ptrCast(@alignCast(raw));
    var buffer: [96]u8 = @splat(0);
    settings.vtable.getString(settings, "driver_petplay", "socketDirectory", &buffer, buffer.len, &err);
    if (err == 5) return true; // No default on an older installation.
    if (err != 0) return false;
    const length = std.mem.indexOfScalar(u8, &buffer, 0) orelse return false;
    return length == 0 or transport.setDirectory(buffer[0..length]);
}
fn cleanup(_: *abi.Provider) callconv(.c) void {
    state.initialized.store(false, .release);
    transport.stop();
    @import("controllers.zig").stop();
    hmd.stop();
    state.standby.store(false, .release);
    state.handle.store(0, .release);
    host = null;
}
fn getVersions(_: *abi.Provider) callconv(.c) [*:null]const ?[*:0]const u8 {
    return &versions;
}
fn runFrame(_: *abi.Provider) callconv(.c) void {
    if (state.initialized.load(.acquire)) _ = state.ticks.fetchAdd(1, .monotonic);
}
fn blockStandby(_: *abi.Provider) callconv(.c) bool {
    return hmd.active.load(.acquire);
}
fn enterStandby(_: *abi.Provider) callconv(.c) void {
    state.standby.store(true, .release);
}
fn leaveStandby(_: *abi.Provider) callconv(.c) void {
    state.standby.store(false, .release);
}
fn activate(_: *abi.Device, _: u32) callconv(.c) i32 {
    return abi.driver_failed;
}
fn deactivate(_: *abi.Device) callconv(.c) void {}
fn deviceStandby(_: *abi.Device) callconv(.c) void {}
fn component(_: *abi.Device, _: [*:0]const u8) callconv(.c) ?*anyopaque {
    return null;
}
fn getPose(_: *abi.Device) callconv(.c) abi.Pose {
    // Nontrivial values catch argument/aggregate-return mistakes in the offline consumer.
    return .{ .poseTimeOffset = -0.0125, .vecPosition = .{ 0.25, 3.25, -0.8 }, .vecVelocity = .{ 1.25, 0, 0 }, .deviceIsConnected = false };
}
fn debugRequest(_: *abi.Device, request: [*:0]const u8, response: [*]u8, size: u32) callconv(.c) void {
    if (size == 0) return;
    response[0] = 0;
    if (request_busy.swap(true, .acquire)) return;
    defer request_busy.store(false, .release);
    // DebugRequest has a bounded NUL-terminated input contract; scan at most our packet limit.
    var length: usize = 0;
    while (length <= actor_mod.max_packet and request[length] != 0) : (length += 1) {}
    if (length > actor_mod.max_packet) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const output = actor.dispatch(arena.allocator(), request[0..length]) catch return;
    if (output) |out| {
        if (out.len + 1 > size) return; // Never return a silently truncated JSON packet.
        @memcpy(response[0..out.len], out);
        response[out.len] = 0;
    }
}
// Available only to the separate ABI-test root; these functions are not exported by the driver.
pub fn testDevice() *abi.Device {
    return &device;
}
pub fn testHostPose(index: u32) void {
    if (host) |h| {
        const pose = getPose(&device);
        h.vtable.trackedDevicePoseUpdated(h, index, &pose, @sizeOf(abi.Pose));
    }
}
pub fn testHostAdd() bool {
    const h = host orelse return false;
    return h.vtable.trackedDeviceAdded(h, "petplay-abi-test", 3, &device);
}
