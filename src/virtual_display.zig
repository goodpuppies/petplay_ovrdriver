//! A clocked discard sink, not a real display or a GPU-completion fence.
const std = @import("std");
const abi = @import("abi.zig");
const linux = std.os.linux;
pub var logger: ?*abi.DriverLog = null;
const hz = 75;
const billion = 1_000_000_000;
var epoch = std.atomic.Value(u64).init(0);
pub var presents = std.atomic.Value(u64).init(0);
pub var timing_queries = std.atomic.Value(u64).init(0);
pub var waits = std.atomic.Value(u64).init(0);
pub var bad_present_size = std.atomic.Value(bool).init(false);
pub var object: abi.VirtualDisplay = .{ .vtable = &table.methods };
const table: abi.Table(abi.VirtualDisplayMethods) = .{ .methods = .{ .present = present, .waitForPresent = wait, .timing = timing } };
pub fn nowNs() u64 {
    var t: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &t)) != .SUCCESS) return 0;
    return @as(u64, @intCast(t.sec)) * billion + @as(u64, @intCast(t.nsec));
}
pub fn reset() void {
    epoch.store(nowNs(), .release);
    presents.store(0, .monotonic);
    timing_queries.store(0, .monotonic);
    waits.store(0, .monotonic);
    bad_present_size.store(false, .release);
}
fn present(_: *abi.VirtualDisplay, _: *const abi.PresentInfo, size: u32) callconv(.c) void {
    if (size != @sizeOf(abi.PresentInfo)) {
        bad_present_size.store(true, .release);
        return;
    }
    // Do not interpret, retain, close or read back an opaque runtime-owned GPU handle.
    if (presents.fetchAdd(1, .monotonic) == 0) if (logger) |log| log.vtable.log(log, "PetPlay synthetic discard sink: first Present callback");
}
fn wait(_: *abi.VirtualDisplay) callconv(.c) void {
    if (waits.fetchAdd(1, .monotonic) == 0) if (logger) |log| log.vtable.log(log, "PetPlay synthetic clock: first WaitForPresent callback");
    const start = epoch.load(.acquire);
    if (start == 0) return;
    const elapsed = nowNs() -| start;
    const next = (@as(u128, elapsed) * hz / billion) + 1;
    const ns: u64 = @intCast(@as(u128, start) + (next * billion + hz - 1) / hz);
    const deadline: linux.timespec = .{ .sec = @intCast(ns / billion), .nsec = @intCast(ns % billion) };
    while (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &deadline, null)) == .INTR) {}
}
fn timing(_: *abi.VirtualDisplay, seconds: *f32, frame: *u64) callconv(.c) bool {
    if (timing_queries.fetchAdd(1, .monotonic) == 0) if (logger) |log| log.vtable.log(log, "PetPlay synthetic clock: first GetTimeSinceLastVsync callback");
    const start = epoch.load(.acquire);
    if (start == 0) return false;
    const elapsed = nowNs() -| start;
    const scaled = @as(u128, elapsed) * hz;
    frame.* = @intCast(scaled / billion);
    seconds.* = @as(f32, @floatFromInt(scaled % billion)) / (billion * @as(f32, hz));
    return true;
}
