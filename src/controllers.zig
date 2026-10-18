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
/// `syntheticControllerType: "oculus_touch"` registers Touch input paths, so applications'
/// shipped Touch bindings (VRChat, PetPlay) drive the synthetic hands without new bindings.
var touch_emulation = false;
/// Scripted input components; only the ones the active profile registers are created.
pub const Component = enum { trigger_click, trigger_value, trigger_touch, grip_click, grip_value, grip_touch, joystick_x, joystick_y, joystick_click, joystick_touch, a_click, a_touch, b_click, b_touch, system_click };
const component_paths = [_][:0]const u8{ "/input/trigger/click", "/input/trigger/value", "/input/trigger/touch", "/input/grip/click", "/input/grip/value", "/input/grip/touch", "/input/joystick/x", "/input/joystick/y", "/input/joystick/click", "/input/joystick/touch", "", "", "", "", "/input/system/click" };
fn isScalar(c: Component) bool {
    return c == .trigger_value or c == .grip_value or c == .joystick_x or c == .joystick_y;
}
/// A held pose replaces the analytic trajectory for one hand until cleared.
pub const HeldPose = struct { position: [3]f64, rotation: abi.Quaternion };
pub const InputState = struct { trigger: f32 = 0, grip: f32 = 0, joystick: [2]f32 = .{ 0, 0 }, joystickClick: bool = false, a: bool = false, b: bool = false, system: bool = false };
const Controller = struct {
    device: abi.Device = .{ .vtable = &table.methods },
    hand: usize,
    index: u32 = 0xffffffff,
    active: bool = false,
    components: [@typeInfo(Component).@"enum".fields.len]u64 = @splat(0),
    haptic: u64 = 0,
    held: ?HeldPose = null,
    inputs: InputState = .{},
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
pub fn start(ctx: *abi.Context, h: *abi.Host) void {
    var err: i32 = 0;
    failed.store(false, .release);
    const settings_raw = ctx.vtable.getGenericInterface(ctx, abi.settings_version, &err) orelse return;
    if (err != 0) return;
    const settings: *abi.Settings = @ptrCast(@alignCast(settings_raw));
    if (!settings.vtable.getBool(settings, "driver_petplay", "syntheticControllers", &err) or err != 0) return;
    var kind: [32]u8 = @splat(0);
    settings.vtable.getString(settings, "driver_petplay", "syntheticControllerType", &kind, kind.len, &err);
    touch_emulation = err == 0 and std.mem.eql(u8, std.mem.sliceTo(&kind, 0), "oculus_touch");
    const props_raw = ctx.vtable.getGenericInterface(ctx, abi.properties_version, &err);
    if (err != 0 or props_raw == null) {
        failed.store(true, .release);
        return;
    }
    const raw = ctx.vtable.getGenericInterface(ctx, abi.input_version, &err);
    if (err != 0 or raw == null) {
        failed.store(true, .release);
        return;
    }
    std.Io.Threaded.mutexLock(&mutex);
    host = h;
    properties = @ptrCast(@alignCast(props_raw.?));
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
/// Holds one hand at `pose`, or returns it to the trajectory when null. Applies immediately.
pub fn hold(hand: usize, pose: ?HeldPose) !void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!accepting) return error.ControllersDisabled;
    hands[hand].held = pose;
}
/// Replaces one hand's scripted input state and publishes it to the runtime.
pub fn setInput(hand: usize, next: InputState) !void {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (!accepting) return error.ControllersDisabled;
    const c = &hands[hand];
    c.inputs = next;
    if (c.active) publishInputs(c);
}
fn publishInputs(c: *Controller) void {
    const in = input orelse return;
    const s = c.inputs;
    inline for (@typeInfo(Component).@"enum".fields) |f| {
        const which: Component = @enumFromInt(f.value);
        const handle = c.components[f.value];
        if (handle != 0) {
            if (comptime isScalar(which)) {
                const value: f32 = switch (which) {
                    .trigger_value => s.trigger,
                    .grip_value => s.grip,
                    .joystick_x => s.joystick[0],
                    .joystick_y => s.joystick[1],
                    else => unreachable,
                };
                _ = in.vtable.updateScalar(in, handle, value, 0);
            } else {
                const value = switch (which) {
                    .trigger_click => s.trigger >= 0.75,
                    .trigger_touch => s.trigger > 0.05,
                    .grip_click => s.grip >= 0.75,
                    .grip_touch => s.grip > 0.05,
                    .joystick_click => s.joystickClick,
                    .joystick_touch => s.joystickClick or s.joystick[0] != 0 or s.joystick[1] != 0,
                    .a_click => s.a,
                    .a_touch => s.a,
                    .b_click => s.b,
                    .b_touch => s.b,
                    .system_click => s.system,
                    else => unreachable,
                };
                _ = in.vtable.updateBoolean(in, handle, value, 0);
            }
        }
    }
}
fn componentPath(c: *Controller, which: Component) [:0]const u8 {
    // Touch puts A/B on the right controller and X/Y on the left.
    const left = c.hand == 0;
    return switch (which) {
        .a_click => if (left) "/input/x/click" else "/input/a/click",
        .a_touch => if (left) "/input/x/touch" else "/input/a/touch",
        .b_click => if (left) "/input/y/click" else "/input/b/click",
        .b_touch => if (left) "/input/y/touch" else "/input/b/touch",
        else => component_paths[@intFromEnum(which)],
    };
}
fn createComponents(c: *Controller, container: u64) bool {
    const in = input.?;
    inline for (@typeInfo(Component).@"enum".fields) |f| {
        const which: Component = @enumFromInt(f.value);
        // The original profile exposes only the trigger click and value.
        const wanted = touch_emulation or which == .trigger_click or which == .trigger_value;
        if (wanted) {
            const path = componentPath(c, which);
            const handle = &c.components[f.value];
            const result = if (comptime isScalar(which))
                in.vtable.createScalar(in, container, path, handle, if (which == .joystick_x or which == .joystick_y) 1 else 0, if (which == .joystick_x or which == .joystick_y) 1 else 0)
            else
                in.vtable.createBoolean(in, container, path, handle);
            if (result != 0) return false;
        }
    }
    publishInputs(c);
    return true;
}
pub const HandSnapshot = struct {
    role: []const u8,
    active: bool,
    index: u32,
    updates: u64,
    sampleSeconds: f64,
    submitSeconds: f64,
    maxGapMs: f64,
    held: bool,
    inputs: InputState,
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
        .held = hand.held != null,
        .inputs = hand.inputs,
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
        string(c, 1005, "PetPlay") and string(c, 7000, if (touch_emulation) "oculus_touch" else "petplay_synthetic") and
        string(c, 1037, if (touch_emulation) "{petplay}/input/touch_emulation_profile.json" else "{petplay}/input/synthetic_controller_profile.json") and
        write(c, 3007, 2, @as(i32, if (c.hand == 0) 1 else 2)) and write(c, 2004, 3, @as(u64, 0x505054455354));
    const in = input.?;
    const container = properties.?.vtable.container(properties.?, id);
    c.components = @splat(0);
    if (!ok or !createComponents(c, container) or
        in.vtable.createHaptic(in, container, "/output/haptic", &c.haptic) != 0)
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
    var pose = evaluate(c, sample);
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
            var pose = evaluate(c, sample);
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
fn evaluate(c: *Controller, sample: u64) abi.Pose {
    var pose = motion.evaluate(config, c.hand, @as(f64, @floatFromInt(sample -| epoch_ns)) / 1e9);
    if (c.held) |held| {
        pose.vecPosition = held.position;
        pose.qRotation = held.rotation;
        pose.vecVelocity = @splat(0);
        pose.vecAcceleration = @splat(0);
        pose.vecAngularVelocity = @splat(0);
        pose.vecAngularAcceleration = @splat(0);
    }
    return pose;
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
