//! Private SteamVR Linux 2.18.4 tracked-camera transport, isolated from the public ABI.
//! The compositor connects to Lighthouse's raw-frame queue; it never polls the camera.
const abi = @import("abi.zig");
const std = @import("std");
const Queue = extern struct { vtable: *const extern struct {
    create: *const fn (*Queue, *u64, [*:0]const u8, u32, u32, u32, u32) callconv(.c) i32,
    connect: usize,
    destroy: *const fn (*Queue, u64) callconv(.c) i32,
    acquire: *const fn (*Queue, u64, *u64, *?[*]u8) callconv(.c) i32,
    release: *const fn (*Queue, u64, u64) callconv(.c) i32,
} };
const Write = extern struct {
    path: u64 = 0,
    write_type: i32 = 0,
    set_error: i32 = 0,
    buffer: *const anyopaque,
    size: u32,
    tag: u32,
    err: i32 = 0,
    reserved: u32 = 0,
    error_string: ?[*:0]const u8 = null,
    update: bool = true,
    internal: bool = false,
};
const Paths = extern struct { vtable: *const extern struct {
    read: usize,
    write: *const fn (*Paths, u64, [*]Write, u32) callconv(.c) i32,
    intern: *const fn (*Paths, *u64, [*:0]const u8) callconv(.c) i32,
} };
comptime {
    std.debug.assert(@sizeOf(Write) == 56 and @offsetOf(Write, "update") == 48);
}
var queue: ?*Queue = null;
var paths: ?*Paths = null;
var handle: u64 = 0;
var keys: [9]u64 = @splat(0);
pub var logger: ?*abi.DriverLog = null;
fn report(comptime fmt: []const u8, args: anytype) void {
    const l = logger orelse return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "PetPlay camera queue: " ++ fmt, args) catch return;
    l.vtable.log(l, msg);
}
pub fn init(ctx: *abi.Context, width: u32, height: u32) bool {
    var err: i32 = 0;
    const q = ctx.vtable.getGenericInterface(ctx, "IVRBlockQueue_005", &err);
    if (q == null or err != 0) {
        report("block queue unavailable ({d})", .{err});
        return false;
    }
    queue = @ptrCast(@alignCast(q.?));
    const p = ctx.vtable.getGenericInterface(ctx, "IVRPaths_002", &err);
    if (p == null or err != 0) {
        queue = null;
        report("paths unavailable ({d})", .{err});
        return false;
    }
    paths = @ptrCast(@alignCast(p.?));
    err = queue.?.vtable.create(queue.?, &handle, "/lighthouse/camera/raw_frames", width * height * 4, 512, 3, 0);
    if (err != 0) {
        report("create failed ({d})", .{err});
        handle = 0;
        return false;
    }
    const names = [_][*:0]const u8{ "/width", "/height", "/format", "/frame_sequence", "/frame_size", "/frame_time_monotonic", "/server_time_ticks", "/delivery_rate", "/elapsed_time" };
    for (names, 0..) |name, i| if (paths.?.vtable.intern(paths.?, &keys[i], name) != 0) {
        stop();
        return false;
    };
    if (!put(handle, keys[0], width, 2) or !put(handle, keys[1], height, 2) or !put(handle, keys[2], @as(i32, 8), 2)) {
        stop();
        return false;
    }
    report("ready: {d}x{d} RGBX, handle {d}", .{ width, height, handle });
    return true;
}
fn put(container: u64, key: u64, value: anytype, tag: u32) bool {
    const p = paths orelse return false;
    var item: Write = .{ .path = key, .buffer = &value, .size = @sizeOf(@TypeOf(value)), .tag = tag };
    const err = p.vtable.write(p, container, @ptrCast(&item), 1);
    if (err != 0 or item.err != 0) {
        report("metadata failed: {d}/{d}", .{ err, item.err });
        return false;
    }
    return true;
}
var publish_logs: u32 = 0;
pub fn publish(pixels: []const u8, sequence: u32, now_ns: u64) void {
    if (handle == 0) return;
    const q = queue orelse return;
    var block: u64 = 0;
    var data: ?[*]u8 = null;
    const acquired = q.vtable.acquire(q, handle, &block, &data);
    if (publish_logs < 3) {
        report("acquire: error {d}, block {d}, pixels {}", .{ acquired, block, data != null });
        publish_logs += 1;
    }
    if (acquired != 0 or block == 0) return;
    if (data) |out| {
        @memcpy(out[0..pixels.len], pixels);
        _ = put(block, keys[3], @as(u64, sequence), 3);
        _ = put(block, keys[4], @as(u32, @intCast(pixels.len)), 2);
        _ = put(block, keys[5], @as(f64, @floatFromInt(now_ns)) / 1e9, 7);
        _ = put(block, keys[6], now_ns, 3);
        _ = put(block, keys[7], @as(f64, 1.0 / 30.0), 7);
        _ = put(block, keys[8], @as(f64, @floatFromInt(sequence)) / 30, 7);
    }
    _ = q.vtable.release(q, handle, block);
}
pub fn stop() void {
    if (handle != 0) if (queue) |q| {
        _ = q.vtable.destroy(q, handle);
    };
    handle = 0;
    queue = null;
    paths = null;
}

test "camera queue publishes typed metadata and releases ownership" {
    const Mock = struct {
        var pixels: [4]u8 = @splat(0);
        var writes: usize = 0;
        var releases: usize = 0;
        var destroys: usize = 0;
        var unavailable = false;
        var acquire_error = false;
        var seq_tag: u32 = 0;
        var seq_size: u32 = 0;
        var seq: u64 = 0;
        var q: Queue = .{ .vtable = &.{ .create = create, .connect = 0, .destroy = destroy, .acquire = acquire, .release = release } };
        var p: Paths = .{ .vtable = &.{ .read = 0, .write = write, .intern = intern } };
        fn generic(_: *abi.Context, name: [*:0]const u8, err: ?*i32) callconv(.c) ?*anyopaque {
            if (err) |e| e.* = if (unavailable) abi.interface_not_found else 0;
            if (unavailable) return null;
            return if (std.mem.eql(u8, std.mem.span(name), "IVRBlockQueue_005")) @ptrCast(&q) else @ptrCast(&p);
        }
        fn driver(_: *abi.Context) callconv(.c) u64 {
            return 0;
        }
        fn create(_: *Queue, h: *u64, _: [*:0]const u8, _: u32, _: u32, _: u32, _: u32) callconv(.c) i32 {
            h.* = 100;
            return 0;
        }
        fn destroy(_: *Queue, _: u64) callconv(.c) i32 {
            destroys += 1;
            return 0;
        }
        fn acquire(_: *Queue, _: u64, block: *u64, out: *?[*]u8) callconv(.c) i32 {
            if (acquire_error) return 3;
            block.* = 200;
            out.* = &pixels;
            return 0;
        }
        fn release(_: *Queue, _: u64, _: u64) callconv(.c) i32 {
            releases += 1;
            return 0;
        }
        fn intern(_: *Paths, key: *u64, name: [*:0]const u8) callconv(.c) i32 {
            key.* = if (std.mem.eql(u8, std.mem.span(name), "/frame_sequence")) 1 else 2;
            return 0;
        }
        fn write(_: *Paths, _: u64, items: [*]Write, _: u32) callconv(.c) i32 {
            writes += 1;
            if (items[0].path == 1) {
                seq_tag = items[0].tag;
                seq_size = items[0].size;
                if (seq_size == 8) seq = @as(*const u64, @ptrCast(@alignCast(items[0].buffer))).*;
            }
            return 0;
        }
    };
    var ctx: abi.Context = .{ .vtable = &.{ .getGenericInterface = Mock.generic, .getDriverHandle = Mock.driver } };
    defer stop();
    try std.testing.expect(init(&ctx, 1, 1));
    publish(&.{ 255, 0, 255, 255 }, 42, 1_000_000_000);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255 }, &Mock.pixels);
    try std.testing.expectEqual(@as(usize, 9), Mock.writes);
    try std.testing.expectEqual(@as(u32, 3), Mock.seq_tag);
    try std.testing.expectEqual(@as(u32, 8), Mock.seq_size);
    try std.testing.expectEqual(@as(u64, 42), Mock.seq);
    try std.testing.expectEqual(@as(usize, 1), Mock.releases);
    Mock.acquire_error = true;
    publish(&.{ 0, 0, 0, 0 }, 43, 2_000_000_000);
    try std.testing.expectEqual(@as(usize, 1), Mock.releases);
    stop();
    stop();
    try std.testing.expectEqual(@as(usize, 1), Mock.destroys);
    publish(&.{ 0, 0, 0, 0 }, 44, 3_000_000_000);
    try std.testing.expectEqual(@as(usize, 9), Mock.writes);
    Mock.unavailable = true;
    try std.testing.expect(!init(&ctx, 1, 1));
}
