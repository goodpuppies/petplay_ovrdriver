//! Immutable during a session; each runtime process reads the same scoped settings.
const std = @import("std");
const abi = @import("abi.zig");
pub const Profile = struct {
    renderWidth: u32 = 640,
    renderHeight: u32 = 640,
    displayEyeWidth: u32 = 640,
    displayEyeHeight: u32 = 720,
    refreshHz: u32 = 75,
    maxSwapchainMiB: u32 = 512,
    ipdMeters: f32 = 0.064,
};
pub var current: Profile = .{};
fn integer(s: *abi.Settings, key: [*:0]const u8, fallback: u32) !u32 {
    var err: i32 = 0;
    const value = s.vtable.getInt32(s, "driver_petplay", key, &err);
    if (err != 0) return fallback;
    if (value < 1 or value > 8192) return error.InvalidDisplayProfile;
    return @intCast(value);
}
pub fn load(s: *abi.Settings) !void {
    const next: Profile = .{
        .renderWidth = try integer(s, "renderWidth", 640),
        .renderHeight = try integer(s, "renderHeight", 640),
        .displayEyeWidth = try integer(s, "displayEyeWidth", 640),
        .displayEyeHeight = try integer(s, "displayEyeHeight", 720),
        .refreshHz = try integer(s, "refreshHz", 75),
        .maxSwapchainMiB = try integer(s, "maxSwapchainMiB", 512),
        .ipdMeters = blk: {
            var err: i32 = 0;
            const value = s.vtable.getFloat(s, "driver_petplay", "ipdMeters", &err);
            break :blk if (err == 0) value else 0.064;
        },
    };
    if (next.maxSwapchainMiB < 64 or next.refreshHz < 30 or next.refreshHz > 240 or
        !std.math.isFinite(next.ipdMeters) or next.ipdMeters < 0.04 or next.ipdMeters > 0.09)
        return error.InvalidDisplayProfile;
    current = next;
}
/// Integer rational clock: no accumulated rounding drift, including non-divisors of 1 GHz.
pub fn tickOffsetNs(n: u64) u64 {
    const hz = current.refreshHz;
    return @intCast((@as(u128, n) * 1_000_000_000 + hz - 1) / hz);
}
pub fn frameAt(elapsed: u64) u64 {
    return @intCast(@as(u128, elapsed) * current.refreshHz / 1_000_000_000);
}
