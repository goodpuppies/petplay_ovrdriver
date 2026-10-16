//! Two opt-in virtual controllers. A bounded queue owns motion changes on the sampling thread.
const std = @import("std");
const abi = @import("abi.zig");
const motion = @import("motion.zig");
const clock = @import("virtual_display.zig");
const linux = std.os.linux;
var mutex: std.Io.Mutex = .init;
var host: ?*abi.Host = null;
var properties: ?*abi.Properties = null;
var input: ?*abi.Input = null;
var thread: ?std.Thread = null;
var stopping = std.atomic.Value(bool).init(false);
var accepting = false;
var config: motion.Config = .{};
var epoch_ns: u64 = 0;
var next_id: u32 = 0;
var applied_id: u32 = 0;
const Command = struct { id: u32, config: motion.Config };
var queue: [8]Command = undefined;
var queued: usize = 0;
pub var failed = std.atomic.Value(bool).init(false);
const Controller = struct {
    device: abi.Device = .{ .vtable = &table.methods },
    hand: usize,
    index: u32 = 0xffffffff,
    active: bool = false,
    trigger: u64 = 0,
    click: u64 = 0,
    haptic: u64 = 0,
    updates: u64 = 0,
    sample_ns: u64 = 0,
    submit_ns: u64 = 0,
    max_gap_ns: u64 = 0,
    last_pose: abi.Pose = .{},
};
var hands = [_]Controller{ .{ .hand = 0 }, .{ .hand = 1 } };
const table: abi.Table(abi.DeviceMethods) = .{ .methods = .{
    .activate = activate,
    .deactivate = deactivate,
    .enterStandby = standby,
    .getComponent = component,
    .debugRequest = debugRequest,
    .getPose = getPose,
} };
const serials = [_][:0]const u8{ "PETPLAY-SYNTHETIC-LEFT-001", "PETPLAY-SYNTHETIC-RIGHT-001" };
pub fn start(ctx: *abi.Context, h: *abi.Host, p: *abi.Properties, settings: *abi.Settings) void {
    var err: i32 = 0;
    failed.store(false, .release);
    if (!settings.vtable.getBool(settings, "driver_petplay", "syntheticControllers", &err) or err != 0) return;
    const raw = ctx.vtable.getGenericInterface(ctx, abi.input_version, &err);
    if (err != 0 or raw == null) {
        failed.store(true, .release);
        return;
    }
    std.Io.Threaded.mutexLock(&mutex);
    host = h;
    properties = p;
    input = @ptrCast(@alignCast(raw.?));
    config = .{};
    epoch_ns = clock.nowNs();
    queued = 0;
    next_id = 0;
    applied_id = 0;
    hands = .{ .{ .hand = 0 }, .{ .hand = 1 } };
    accepting = true;
    std.Io.Threaded.mutexUnlock(&mutex);
    if (!h.vtable.trackedDeviceAdded(h, serials[0], 2, &hands[0].device) or !h.vtable.trackedDeviceAdded(h, serials[1], 2, &hands[1].device)) {
        failed.store(true, .release);
        stop();
        return;
    }
    stopping.store(false, .release);
    thread = std.Thread.spawn(.{}, sampleLoop, .{}) catch {
        failed.store(true, .release);
        stop();
        return;
    };
}
pub fn stop() void {
    stopping.store(true, .release);
    if (thread) |t| t.join();
    thread = null;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    accepting = false;
    queued = 0;
    for (&hands) |*hand| {
        hand.active = false;
        hand.index = 0xffffffff;
    }
    host = null;
    properties = null;
    input = null;
}
pub fn enqueue(next: motion.Config) !u32 {
    if (!next.valid()) return error.InvalidMotion;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!accepting) return error.ControllersDisabled;
    if (queued == queue.len) return error.CommandQueueFull;
    next_id +%= 1;
    queue[queued] = .{ .id = next_id, .config = next };
    queued += 1;
    return next_id;
}
pub const HandSnapshot = struct {
    role: []const u8,
    active: bool,
    index: u32,
    updates: u64,
    sampleSeconds: f64,
    submitSeconds: f64,
    maxGapMs: f64,
    pose: abi.Pose,
};
pub fn snapshot() struct { enabled: bool, failed: bool, config: motion.Config, epochSeconds: f64, appliedId: u32, queued: usize, hands: [2]HandSnapshot } {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    var result: [2]HandSnapshot = undefined;
    for (hands, 0..) |hand, i| result[i] = .{
        .role = if (i == 0) "left" else "right",
        .active = hand.active,
        .index = hand.index,
        .updates = hand.updates,
        .sampleSeconds = @as(f64, @floatFromInt(hand.sample_ns)) / 1e9,
        .submitSeconds = @as(f64, @floatFromInt(hand.submit_ns)) / 1e9,
        .maxGapMs = @as(f64, @floatFromInt(hand.max_gap_ns)) / 1e6,
        .pose = hand.last_pose,
    };
    return .{ .enabled = accepting, .failed = failed.load(.acquire), .config = config, .epochSeconds = @as(f64, @floatFromInt(epoch_ns)) / 1e9, .appliedId = applied_id, .queued = queued, .hands = result };
}
fn write(c: *Controller, prop: i32, tag: u32, value: anytype) bool {
    const p = properties orelse return false;
    var item: abi.PropertyWrite = .{ .prop = prop, .buffer = &value, .size = @sizeOf(@TypeOf(value)), .tag = tag };
    return p.vtable.writeBatch(p, p.vtable.container(p, c.index), @ptrCast(&item), 1) == 0 and item.err == 0;
}
fn string(c: *Controller, prop: i32, value: [:0]const u8) bool {
    const p = properties orelse return false;
    var item: abi.PropertyWrite = .{ .prop = prop, .buffer = value.ptr, .size = @intCast(value.len + 1), .tag = 5 };
    return p.vtable.writeBatch(p, p.vtable.container(p, c.index), @ptrCast(&item), 1) == 0 and item.err == 0;
}
fn activate(device: *abi.Device, id: u32) callconv(.c) i32 {
    const c: *Controller = @fieldParentPtr("device", device);
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!accepting or c.active or input == null) return abi.driver_failed;
    c.index = id;
    const ok = string(c, 1000, "petplay") and string(c, 1001, "PetPlay Synthetic Controller") and string(c, 1002, serials[c.hand]) and
        string(c, 1005, "PetPlay") and string(c, 7000, "petplay_synthetic") and
        string(c, 1037, "{petplay}/input/synthetic_controller_profile.json") and
        write(c, 3007, 2, @as(i32, if (c.hand == 0) 1 else 2)) and write(c, 2004, 3, @as(u64, 0x505054455354));
    const in = input.?;
    const container = properties.?.vtable.container(properties.?, id);
    if (!ok or in.vtable.createBoolean(in, container, "/input/trigger/click", &c.click) != 0 or
        in.vtable.createScalar(in, container, "/input/trigger/value", &c.trigger, 0, 0) != 0 or
        in.vtable.createHaptic(in, container, "/output/haptic", &c.haptic) != 0 or
        in.vtable.updateBoolean(in, c.click, false, 0) != 0 or in.vtable.updateScalar(in, c.trigger, 0, 0) != 0)
    {
        failed.store(true, .release);
        c.index = 0xffffffff;
        return abi.driver_failed;
    }
    c.active = true;
    return 0;
}
fn deactivate(device: *abi.Device) callconv(.c) void {
    const c: *Controller = @fieldParentPtr("device", device);
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    c.active = false;
    c.index = 0xffffffff;
}
fn getPose(device: *abi.Device) callconv(.c) abi.Pose {
    const c: *Controller = @fieldParentPtr("device", device);
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!c.active) return .{ .poseIsValid = false, .deviceIsConnected = false };
    const sample = clock.nowNs();
    var pose = motion.evaluate(config, c.hand, @as(f64, @floatFromInt(sample -| epoch_ns)) / 1e9);
    pose.poseTimeOffset = -@as(f64, @floatFromInt(clock.nowNs() -| sample)) / 1e9;
    return pose;
}
fn sampleLoop() void {
    const start_ns = clock.nowNs();
    while (!stopping.load(.acquire)) {
        std.Io.Threaded.mutexLock(&mutex);
        applyQueued(clock.nowNs());
        for (&hands) |*c| if (c.active) {
            const sample = clock.nowNs();
            var pose = motion.evaluate(config, c.hand, @as(f64, @floatFromInt(sample -| epoch_ns)) / 1e9);
            const submit = clock.nowNs();
            pose.poseTimeOffset = -@as(f64, @floatFromInt(submit -| sample)) / 1e9;
            host.?.vtable.trackedDevicePoseUpdated(host.?, c.index, &pose, @sizeOf(abi.Pose));
            if (c.sample_ns != 0) c.max_gap_ns = @max(c.max_gap_ns, sample -| c.sample_ns);
            c.last_pose = pose;
            c.sample_ns = sample;
            c.submit_ns = submit;
            c.updates += 1;
        };
        std.Io.Threaded.mutexUnlock(&mutex);
        const now = clock.nowNs();
        const next = start_ns + ((now -| start_ns) / 4_000_000 + 1) * 4_000_000;
        const deadline: linux.timespec = .{ .sec = @intCast(next / 1_000_000_000), .nsec = @intCast(next % 1_000_000_000) };
        while (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &deadline, null)) == .INTR) {}
    }
}
fn standby(_: *abi.Device) callconv(.c) void {}
fn component(_: *abi.Device, _: [*:0]const u8) callconv(.c) ?*anyopaque {
    return null;
}
fn debugRequest(_: *abi.Device, _: [*:0]const u8, out: [*]u8, size: u32) callconv(.c) void {
    if (size > 0) out[0] = 0;
}

// Called with the state mutex held, exclusively by the sampling owner (or offline unit test).
fn applyQueued(now: u64) void {
    if (queued == 0) return;
    for (queue[0..queued]) |command| {
        config = command.config;
        applied_id = command.id;
    }
    epoch_ns = now;
    queued = 0;
}
test "motion queue validates capacity and changes state only at an owner boundary" {
    accepting = false;
    queued = 0;
    try std.testing.expectError(error.ControllersDisabled, enqueue(.{}));
    accepting = true;
    next_id = 0;
    applied_id = 0;
    config = .{};
    defer {
        accepting = false;
        queued = 0;
    }
    try std.testing.expectError(error.InvalidMotion, enqueue(.{ .frequencyHz = 0 }));
    for (0..queue.len) |i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), try enqueue(.{ .mode = .sine, .frequencyHz = 0.5 + @as(f64, @floatFromInt(i)) / 10 }));
    try std.testing.expectError(error.CommandQueueFull, enqueue(.{}));
    try std.testing.expectEqual(@as(u32, 0), applied_id);
    try std.testing.expect(config.mode == .stationary);
    std.Io.Threaded.mutexLock(&mutex);
    applyQueued(1234567890);
    std.Io.Threaded.mutexUnlock(&mutex);
    const applied = snapshot();
    try std.testing.expectEqual(@as(u32, 8), applied.appliedId);
    try std.testing.expectEqual(@as(usize, 0), applied.queued);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), applied.config.frequencyHz, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.23456789), applied.epochSeconds, 1e-12);
}
