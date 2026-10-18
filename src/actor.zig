//! Stageforge WebSocketWorker envelopes and PostMan addressed-message protocol.
//! Transport independent: bounded JSON in/out; no JS evaluator or custom RPC wrapper.
const std = @import("std");
const state = @import("state.zig");
const Value = std.json.Value;
pub const max_packet = 16 * 1024;
pub const Actor = struct {
    id: [192]u8 = undefined,
    id_len: usize = 0,
    close_requested: bool = false,
    allow_init: bool = true,
    process_owner: []const u8 = "standalone-probe",
    pub fn establishIdentity(self: *Actor) !void {
        var generated: [64]u8 = undefined;
        const id = try makeId(&generated);
        @memcpy(self.id[0..id.len], id);
        self.id_len = id.len;
        self.close_requested = false;
    }
    pub fn dispatch(self: *Actor, allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
        if (input.len > max_packet) return error.PacketTooLarge;
        const parsed = try std.json.parseFromSlice(Value, allocator, input, .{ .max_value_len = max_packet });
        defer parsed.deinit();
        const root = parsed.value;
        const kind = try text(try field(root, "kind"));
        if (std.mem.eql(u8, kind, "terminate")) {
            self.close_requested = true;
            return null; // Disconnect only; never terminate vrserver.
        }
        if (!std.mem.eql(u8, kind, "message")) return error.InvalidEnvelope;
        const message = try field(root, "data");
        const typ = try text(try field(message, "type"));
        const address = try field(message, "address");
        const from = try text(try field(address, "fm"));
        _ = try text(try field(address, "to"));
        const payload = optionalField(message, "payload") orelse Value.null;
        const colon = std.mem.indexOfScalar(u8, typ, ':');
        const base = typ[0 .. colon orelse typ.len];
        if (std.mem.eql(u8, base, "INIT")) {
            if (!self.allow_init) return error.ExternallyOwnedActor;
            var generated: [64]u8 = undefined;
            const id = if (optionalField(payload, "actorId")) |value|
                if (value == .null) try makeId(&generated) else try text(value)
            else
                try makeId(&generated);
            if (id.len == 0 or id.len > self.id.len or std.mem.indexOfScalar(u8, id, '@') == null) return error.InvalidActorId;
            const callback = try text(try field(payload, "callbackKey"));
            @memcpy(self.id[0..id.len], id);
            self.id_len = id.len;
            self.close_requested = false;
            return try encode(allocator, .{ .kind = "message", .data = .{
                .address = .{ .fm = self.id[0..self.id_len], .to = "SYSTEM" },
                .type = "LOADED",
                .payload = .{ .actorId = self.id[0..self.id_len], .callbackKey = callback },
            } });
        }
        if (self.id_len == 0) return error.NotInitialized;
        const me = self.id[0..self.id_len];
        if (!std.mem.eql(u8, try text(try field(address, "to")), me)) return error.WrongActor;
        if (std.mem.eql(u8, base, "SHUTDOWN_AND_CLOSE") or std.mem.eql(u8, base, "SHUTDOWN")) {
            self.close_requested = std.mem.eql(u8, base, "SHUTDOWN_AND_CLOSE");
            if (colon == null) return null;
            return try reply(allocator, me, from, typ, true);
        }
        if (std.mem.eql(u8, base, "SETCONTROLLERMOTION")) {
            const next = parseMotion(payload) catch |err| return if (colon == null) null else try commandError(allocator, me, from, typ, @errorName(err));
            const id = @import("controllers.zig").enqueue(next) catch |err| return if (colon == null) null else try commandError(allocator, me, from, typ, @errorName(err));
            return if (colon == null) null else try reply(allocator, me, from, typ, .{ .accepted = true, .commandId = id });
        }
        if (std.mem.eql(u8, base, "SETCONTROLLERPOSE")) {
            const controllers = @import("controllers.zig");
            const parsed_pose = parsePose(payload) catch |err| return if (colon == null) null else try commandError(allocator, me, from, typ, @errorName(err));
            controllers.hold(parsed_pose.hand, parsed_pose.pose) catch |err| return if (colon == null) null else try commandError(allocator, me, from, typ, @errorName(err));
            return if (colon == null) null else try reply(allocator, me, from, typ, .{ .accepted = true });
        }
        if (std.mem.eql(u8, base, "SETCONTROLLERINPUT")) {
            const controllers = @import("controllers.zig");
            const parsed_input = parseInput(payload) catch |err| return if (colon == null) null else try commandError(allocator, me, from, typ, @errorName(err));
            controllers.setInput(parsed_input.hand, parsed_input.state) catch |err| return if (colon == null) null else try commandError(allocator, me, from, typ, @errorName(err));
            return if (colon == null) null else try reply(allocator, me, from, typ, .{ .accepted = true });
        }
        if (colon == null) return null; // Fire-and-forget doesn't get a return value.
        if (std.mem.eql(u8, base, "PROBEDIRECTFENCES")) return try reply(allocator, me, from, typ, .{ .accepted = @import("direct.zig").requestFenceProbe() });
        if (std.mem.eql(u8, base, "GETDIRECTSTATE")) return try reply(allocator, me, from, typ, @import("direct.zig").snapshot());
        if (std.mem.eql(u8, base, "CAPTUREDIRECTFRAME")) {
            const directory = parseCaptureDirectory(payload) catch |err| return try commandError(allocator, me, from, typ, @errorName(err));
            const capture = @import("direct.zig").captureFrame(allocator, directory) catch |err| return try commandError(allocator, me, from, typ, @errorName(err));
            return try reply(allocator, me, from, typ, capture);
        }
        if (std.mem.eql(u8, base, "GETCONTROLLERSTATE")) return try reply(allocator, me, from, typ, @import("controllers.zig").snapshot());
        if (std.mem.eql(u8, base, "ECHO")) return try reply(allocator, me, from, typ, payload);
        if (std.mem.eql(u8, base, "PING")) return try reply(allocator, me, from, typ, .{ .protocol = 1, .language = "zig" });
        if (std.mem.eql(u8, base, "HEALTH")) return try reply(allocator, me, from, typ, .{
            .ok = true,
            .actorId = me,
            .name = "petplay_ovrdriver",
            .addressBookSize = 0,
            .details = .{
                .protocol = 1,
                .driverInitialized = state.initialized.load(.acquire),
                .standby = state.standby.load(.acquire),
                .runFrameCount = state.ticks.load(.monotonic),
                .processOwner = self.process_owner,
                .deviceSupport = "independent-opt-in-hmd-and-controllers",
                .syntheticHmdEnabled = @import("hmd.zig").enabled.load(.acquire),
                .syntheticHmdActive = @import("hmd.zig").active.load(.acquire),
                .syntheticHmdFailed = @import("hmd.zig").failed.load(.acquire),
                .syntheticPoseUpdates = @import("hmd.zig").pose_updates.load(.monotonic),
                .virtualPresents = @import("virtual_display.zig").presents.load(.monotonic),
                .virtualTimingQueries = @import("virtual_display.zig").timing_queries.load(.monotonic),
                .virtualWaits = @import("virtual_display.zig").waits.load(.monotonic),
                .virtualBadPresentSize = @import("virtual_display.zig").bad_present_size.load(.acquire),
                .ipcListening = state.ipc_listening.load(.acquire),
                .ipcConnected = state.ipc_connected.load(.acquire),
                .ipcSessions = state.ipc_sessions.load(.monotonic),
                .ipcFailed = state.ipc_failed.load(.acquire),
            },
        });
        return try reply(allocator, me, from, typ, .{ .__actorError = .{
            .message = "Unsupported native actor message",
            .type = base,
            .event = "missing-function",
        } });
    }
};
fn field(v: Value, key: []const u8) !Value {
    return optionalField(v, key) orelse error.MissingField;
}
fn optionalField(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn text(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.ExpectedString;
}
fn reply(a: std.mem.Allocator, from: []const u8, to: []const u8, typ: []const u8, payload: anytype) ![]u8 {
    return encode(a, .{ .kind = "message", .data = .{ .address = .{ .fm = from, .to = to }, .type = typ, .payload = payload } });
}
pub fn encode(a: std.mem.Allocator, v: anytype) ![]u8 {
    const out = try std.json.Stringify.valueAlloc(a, v, .{});
    if (out.len > max_packet) {
        a.free(out);
        return error.PacketTooLarge;
    }
    return out;
}

fn makeId(buffer: *[64]u8) ![]const u8 {
    var random: [16]u8 = undefined;
    var used: usize = 0;
    while (used < random.len) {
        const n = std.os.linux.getrandom(random[used..].ptr, random.len - used, 0);
        if (std.os.linux.errno(n) == .INTR) continue;
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) return error.RandomFailed;
        used += n;
    }
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    const prefix = "petplay_ovrdriver@";
    @memcpy(buffer[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    const hex = "0123456789abcdef";
    for (random, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buffer[pos] = '-';
            pos += 1;
        }
        buffer[pos] = hex[byte >> 4];
        buffer[pos + 1] = hex[byte & 15];
        pos += 2;
    }
    return buffer[0..pos];
}

fn number(v: Value) !f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => error.ExpectedNumber,
    };
}
fn parseMotion(payload: Value) !@import("motion.zig").Config {
    if (payload != .object) return error.ExpectedMotionObject;
    var config: @import("motion.zig").Config = .{};
    const mode = try text(try field(payload, "mode"));
    if (std.mem.eql(u8, mode, "stationary")) config.mode = .stationary else if (std.mem.eql(u8, mode, "sine")) config.mode = .sine else if (std.mem.eql(u8, mode, "sweep")) config.mode = .sweep else return error.InvalidMotionMode;
    if (optionalField(payload, "frequencyHz")) |v| config.frequencyHz = try number(v);
    if (optionalField(payload, "positionAmplitudeM")) |v| config.positionAmplitudeM = try number(v);
    if (optionalField(payload, "yawAmplitudeRad")) |v| config.yawAmplitudeRad = try number(v);
    if (optionalField(payload, "worldYawRad")) |v| config.worldYawRad = try number(v);
    if (optionalField(payload, "worldTranslationM")) |v| {
        if (v != .array or v.array.items.len != 3) return error.ExpectedTranslationVector;
        for (v.array.items, 0..) |item, i| config.worldTranslationM[i] = try number(item);
    }
    for (payload.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "mode") and !std.mem.eql(u8, key, "frequencyHz") and
            !std.mem.eql(u8, key, "positionAmplitudeM") and !std.mem.eql(u8, key, "yawAmplitudeRad") and
            !std.mem.eql(u8, key, "worldYawRad") and !std.mem.eql(u8, key, "worldTranslationM")) return error.UnknownMotionField;
    }
    if (!config.valid()) return error.InvalidMotion;
    return config;
}
fn commandError(a: std.mem.Allocator, from: []const u8, to: []const u8, typ: []const u8, message: []const u8) ![]u8 {
    return reply(a, from, to, typ, .{ .__actorError = .{ .message = message, .event = "controller-command" } });
}
fn parseHand(payload: Value) !usize {
    const hand = try text(try field(payload, "hand"));
    if (std.mem.eql(u8, hand, "left")) return 0;
    if (std.mem.eql(u8, hand, "right")) return 1;
    return error.InvalidHand;
}
fn finiteVector(comptime n: usize, v: Value, limit: f64) ![n]f64 {
    if (v != .array or v.array.items.len != n) return error.ExpectedVector;
    var out: [n]f64 = undefined;
    for (v.array.items, 0..) |item, i| {
        out[i] = try number(item);
        if (!std.math.isFinite(out[i]) or @abs(out[i]) > limit) return error.InvalidVector;
    }
    return out;
}
fn rejectUnknown(payload: Value, comptime allowed: []const []const u8) !void {
    outer: for (payload.object.keys()) |key| {
        inline for (allowed) |name| if (std.mem.eql(u8, key, name)) continue :outer;
        return error.UnknownField;
    }
}
/// `{directory}`: an existing absolute directory for CAPTUREDIRECTFRAME's image files.
fn parseCaptureDirectory(payload: Value) ![]const u8 {
    if (payload != .object) return error.ExpectedCaptureObject;
    try rejectUnknown(payload, &.{"directory"});
    const directory = try text(try field(payload, "directory"));
    if (directory.len == 0 or directory[0] != '/' or directory.len > 1024) return error.ExpectedAbsoluteDirectory;
    return directory;
}
/// `{hand, position:[x,y,z], rotation:[x,y,z,w]}` holds a hand; `{hand, clear:true}` releases it.
fn parsePose(payload: Value) !struct { hand: usize, pose: ?@import("controllers.zig").HeldPose } {
    if (payload != .object) return error.ExpectedPoseObject;
    try rejectUnknown(payload, &.{ "hand", "position", "rotation", "clear" });
    const hand = try parseHand(payload);
    if (optionalField(payload, "clear")) |v| if (v == .bool and v.bool) return .{ .hand = hand, .pose = null };
    const position = try finiteVector(3, try field(payload, "position"), 100);
    const q = try finiteVector(4, try field(payload, "rotation"), 2);
    const length = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (length < 0.5) return error.InvalidRotation;
    return .{ .hand = hand, .pose = .{ .position = position, .rotation = .{ .x = q[0] / length, .y = q[1] / length, .z = q[2] / length, .w = q[3] / length } } };
}
/// The complete input state for one hand; omitted controls are released.
fn parseInput(payload: Value) !struct { hand: usize, state: @import("controllers.zig").InputState } {
    if (payload != .object) return error.ExpectedInputObject;
    try rejectUnknown(payload, &.{ "hand", "trigger", "grip", "joystick", "joystickClick", "a", "b", "system" });
    var state_out: @import("controllers.zig").InputState = .{};
    const hand = try parseHand(payload);
    if (optionalField(payload, "trigger")) |v| state_out.trigger = try unit(v, 0);
    if (optionalField(payload, "grip")) |v| state_out.grip = try unit(v, 0);
    if (optionalField(payload, "joystick")) |v| {
        const axes = try finiteVector(2, v, 1);
        state_out.joystick = .{ @floatCast(axes[0]), @floatCast(axes[1]) };
    }
    if (optionalField(payload, "joystickClick")) |v| state_out.joystickClick = try boolean(v);
    if (optionalField(payload, "a")) |v| state_out.a = try boolean(v);
    if (optionalField(payload, "b")) |v| state_out.b = try boolean(v);
    if (optionalField(payload, "system")) |v| state_out.system = try boolean(v);
    return .{ .hand = hand, .state = state_out };
}
fn unit(v: Value, minimum: f64) !f32 {
    const x = try number(v);
    if (!std.math.isFinite(x) or x < minimum or x > 1) return error.InvalidAxis;
    return @floatCast(x);
}
fn boolean(v: Value) !bool {
    return if (v == .bool) v.bool else error.ExpectedBool;
}
