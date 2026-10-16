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
        if (colon == null) return null; // Fire-and-forget doesn't get a return value.
        if (std.mem.eql(u8, base, "ECHO")) return try reply(allocator, me, from, typ, payload);
        if (std.mem.eql(u8, base, "PING")) return try reply(allocator, me, from, typ, .{ .protocol = 1, .language = "zig" });
        if (std.mem.eql(u8, base, "HEALTH")) return try reply(allocator, me, from, typ, .{
            .ok = true,
            .actorId = me,
            .name = "petplay_ovrdriver",
            .addressBookSize = 0,
            .details = .{ .protocol = 1, .driverInitialized = state.initialized.load(.acquire), .standby = state.standby.load(.acquire), .runFrameCount = state.ticks.load(.monotonic), .processOwner = self.process_owner, .deviceSupport = "abi-probe-only", .ipcListening = state.ipc_listening.load(.acquire), .ipcConnected = state.ipc_connected.load(.acquire), .ipcSessions = state.ipc_sessions.load(.monotonic), .ipcFailed = state.ipc_failed.load(.acquire) },
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
