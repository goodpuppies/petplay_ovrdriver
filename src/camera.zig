//! Synthetic passthrough camera on the HMD (opt-in: `passthroughKeyRgb`). Every frame is one
//! solid key colour. SteamVR shows its camera feed wherever it would show the room, so in the
//! composited picture the key marks passthrough; a WebXR `immersive-ar` client keys it out
//! over its own passthrough. Provides `IVRCameraComponent_003` and the Linux compositor's private raw-frame queue.
const std = @import("std");
const abi = @import("abi.zig");
const profile = @import("display_profile.zig");
const linux = std.os.linux;
const transport_queue = @import("camera_queue.zig");
var queue_pixels: [width * height * 4]u8 = undefined;
pub fn initQueue(ctx: *abi.Context) void {
    transport_queue.logger = logger;
    fill(&queue_pixels, .rgbx32, @intCast(profile.current.passthroughKeyRgb));
    if (transport_queue.init(ctx, width, height)) {
        queue_ready = true;
        stopping.store(false, .release);
        thread = std.Thread.spawn(.{}, produce, .{}) catch {
            queue_ready = false;
            transport_queue.stop();
            return;
        };
    }
}

pub const version = "IVRCameraComponent_003";
pub const width: u32 = 640;
pub const height: u32 = 480;
const frame_rate: u64 = 30;

/// `ECameraVideoStreamFormat`.
pub const Format = enum(i32) { unknown = 0, raw10 = 1, nv12 = 2, rgb24 = 3, nv12_2 = 4, yuyv16 = 5, bayer16bg = 6, mjpeg = 7, rgbx32 = 8, _ };
/// `TrackedDevicePose_t`.
pub const DevicePose = extern struct {
    deviceToAbsolute: [3][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 1.6 }, .{ 0, 0, 1, 0 } },
    velocity: [3]f32 = @splat(0),
    angularVelocity: [3]f32 = @splat(0),
    trackingResult: i32 = 200,
    poseIsValid: bool = true,
    deviceIsConnected: bool = true,
};
/// `CameraVideoStreamFrame_t` (pack 8 = natural alignment on x86-64).
pub const Frame = extern struct {
    format: Format = .unknown,
    width: u32 = 0,
    height: u32 = 0,
    imageDataSize: u32 = 0,
    frameSequence: u32 = 0,
    bufferIndex: u32 = 0,
    bufferCount: u32 = 0,
    exposureTime: u32 = 0,
    ispFrameTimeStamp: u32 = 0,
    ispReferenceTimeStamp: u32 = 0,
    syncCounter: u32 = 0,
    camSyncEvents: u32 = 0,
    ispSyncEvents: u32 = 0,
    referenceCamSyncTime: f64 = 0,
    frameElapsedTime: f64 = 0,
    frameDeliveryRate: f64 = 0,
    frameCaptureTimeDriverAbsolute: f64 = 0,
    frameCaptureTimeServerRelative: f64 = 0,
    frameCaptureTicksServerAbsolute: u64 = 0,
    frameCaptureTimeClientRelative: f64 = 0,
    syncMarkerError: f64 = 0,
    rawTrackedDevicePose: DevicePose = .{},
    imageData: u64 = 0,
};
comptime {
    std.debug.assert(@sizeOf(Frame) == 208 and @offsetOf(Frame, "imageData") == 200);
    std.debug.assert(@offsetOf(Frame, "referenceCamSyncTime") == 56 and @offsetOf(Frame, "rawTrackedDevicePose") == 120);
}
const Sink = extern struct { vtable: *const extern struct { callback: *const fn (*Sink) callconv(.c) void } };
pub const Camera = extern struct { vtable: *const Methods };
const Methods = extern struct {
    getCameraFrameDimensions: *const fn (*Camera, Format, *u32, *u32) callconv(.c) bool,
    getCameraFrameBufferingRequirements: *const fn (*Camera, *i32, *u32) callconv(.c) bool,
    setCameraFrameBuffering: *const fn (*Camera, i32, ?[*]?*anyopaque, u32) callconv(.c) bool,
    setCameraVideoStreamFormat: *const fn (*Camera, Format) callconv(.c) bool,
    getCameraVideoStreamFormat: *const fn (*Camera) callconv(.c) Format,
    startVideoStream: *const fn (*Camera) callconv(.c) bool,
    stopVideoStream: *const fn (*Camera) callconv(.c) void,
    isVideoStreamActive: *const fn (*Camera, ?*bool, ?*f32) callconv(.c) bool,
    getVideoStreamFrame: *const fn (*Camera) callconv(.c) ?*const Frame,
    releaseVideoStreamFrame: *const fn (*Camera, ?*const Frame) callconv(.c) void,
    setAutoExposure: *const fn (*Camera, bool) callconv(.c) bool,
    pauseVideoStream: *const fn (*Camera) callconv(.c) bool,
    resumeVideoStream: *const fn (*Camera) callconv(.c) bool,
    getCameraDistortion: *const fn (*Camera, u32, f32, f32, *f32, *f32) callconv(.c) bool,
    getCameraProjection: *const fn (*Camera, u32, i32, f32, f32, *[4][4]f32) callconv(.c) bool,
    setFrameRate: *const fn (*Camera, i32, i32) callconv(.c) bool,
    setCameraVideoSinkCallback: *const fn (*Camera, ?*Sink) callconv(.c) bool,
    getCameraCompatibilityMode: *const fn (*Camera, *i32) callconv(.c) bool,
    setCameraCompatibilityMode: *const fn (*Camera, i32) callconv(.c) bool,
    getCameraFrameBounds: *const fn (*Camera, i32, *u32, *u32, *u32, *u32) callconv(.c) bool,
    getCameraIntrinsics: *const fn (*Camera, u32, i32, *[2]f32, *[2]f32, *i32, *[8]f64) callconv(.c) bool,
};
const table: abi.Table(Methods) = .{ .methods = .{
    .getCameraFrameDimensions = getCameraFrameDimensions,
    .getCameraFrameBufferingRequirements = getCameraFrameBufferingRequirements,
    .setCameraFrameBuffering = setCameraFrameBuffering,
    .setCameraVideoStreamFormat = setCameraVideoStreamFormat,
    .getCameraVideoStreamFormat = getCameraVideoStreamFormat,
    .startVideoStream = startVideoStream,
    .stopVideoStream = stopVideoStream,
    .isVideoStreamActive = isVideoStreamActive,
    .getVideoStreamFrame = getVideoStreamFrame,
    .releaseVideoStreamFrame = releaseVideoStreamFrame,
    .setAutoExposure = setAutoExposure,
    .pauseVideoStream = pauseVideoStream,
    .resumeVideoStream = resumeVideoStream,
    .getCameraDistortion = getCameraDistortion,
    .getCameraProjection = getCameraProjection,
    .setFrameRate = setFrameRate,
    .setCameraVideoSinkCallback = setCameraVideoSinkCallback,
    .getCameraCompatibilityMode = getCameraCompatibilityMode,
    .setCameraCompatibilityMode = setCameraCompatibilityMode,
    .getCameraFrameBounds = getCameraFrameBounds,
    .getCameraIntrinsics = getCameraIntrinsics,
} };
pub var object: Camera = .{ .vtable = &table.methods };

pub fn enabled() bool {
    return profile.current.passthroughKeyRgb != 0 and !profile.current.framePassthrough;
}

var mutex: std.Io.Mutex = .init;
var format: Format = .rgbx32;
var buffers: [8]?[*]u8 = @splat(null);
var buffer_count: usize = 0;
var buffer_size: u32 = 0;
/// Used when SteamVR does not supply buffers of its own.
var own: [width * height * 4]u8 = undefined;
var frames: [8]Frame = @splat(.{});
var current: ?usize = null;
var sequence: u32 = 0;
var streaming = false;
var queue_ready = false;
var paused = false;
var start_ns: u64 = 0;
var sink: ?*Sink = null;
var thread: ?std.Thread = null;
var stopping = std.atomic.Value(bool).init(false);
/// The runtime's driver log (vrserver.txt), set at provider init.
pub var logger: ?*abi.DriverLog = null;
/// First calls of each method are logged, to learn how SteamVR drives a driver camera.
var call_counts: [32]u32 = @splat(0);

pub fn logLookup() void {
    log(22, "GetComponent(" ++ version ++ ")", .{});
}
pub fn logProperties(ok: bool) void {
    log(23, "HMD camera properties written: {}", .{ok});
}
fn log(comptime slot: usize, comptime fmt: []const u8, args: anytype) void {
    call_counts[slot] +|= 1;
    if (call_counts[slot] > 4) return;
    const l = logger orelse return;
    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "PetPlay camera: " ++ fmt, args) catch return;
    l.vtable.log(l, msg);
}
fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn imageSize(f: Format) ?u32 {
    return switch (f) {
        .rgb24 => width * height * 3,
        .rgbx32 => width * height * 4,
        .nv12 => width * height * 3 / 2,
        .nv12_2 => width * height * 3,
        .yuyv16 => width * height * 2,
        else => null,
    };
}
/// BT.601 limited-range YCbCr of the key colour.
fn ycbcr(rgb: u32) [3]u8 {
    const r: f32 = @floatFromInt((rgb >> 16) & 0xff);
    const g: f32 = @floatFromInt((rgb >> 8) & 0xff);
    const b: f32 = @floatFromInt(rgb & 0xff);
    const y = 16 + (65.481 * r + 128.553 * g + 24.966 * b) / 255;
    const cb = 128 + (-37.797 * r - 74.203 * g + 112.0 * b) / 255;
    const cr = 128 + (112.0 * r - 93.786 * g - 18.214 * b) / 255;
    return .{ @intFromFloat(std.math.clamp(@round(y), 0, 255)), @intFromFloat(std.math.clamp(@round(cb), 0, 255)), @intFromFloat(std.math.clamp(@round(cr), 0, 255)) };
}
/// Fills `out` with the key colour in format `f`.
pub fn fill(out: []u8, f: Format, rgb: u32) void {
    const r: u8 = @intCast((rgb >> 16) & 0xff);
    const g: u8 = @intCast((rgb >> 8) & 0xff);
    const b: u8 = @intCast(rgb & 0xff);
    const yuv = ycbcr(rgb);
    switch (f) {
        .rgb24 => for (0..out.len / 3) |i| {
            out[i * 3] = r;
            out[i * 3 + 1] = g;
            out[i * 3 + 2] = b;
        },
        .rgbx32 => for (0..out.len / 4) |i| {
            out[i * 4] = r;
            out[i * 4 + 1] = g;
            out[i * 4 + 2] = b;
            out[i * 4 + 3] = 255;
        },
        .nv12, .nv12_2 => {
            // Luma planes first (two stacked images for NV12_2 are filled as one), then
            // interleaved CbCr.
            const luma = out.len * 2 / 3;
            @memset(out[0..luma], yuv[0]);
            var i = luma;
            while (i + 1 < out.len) : (i += 2) {
                out[i] = yuv[1];
                out[i + 1] = yuv[2];
            }
        },
        .yuyv16 => for (0..out.len / 4) |i| {
            out[i * 4] = yuv[0];
            out[i * 4 + 1] = yuv[1];
            out[i * 4 + 2] = yuv[0];
            out[i * 4 + 3] = yuv[2];
        },
        else => @memset(out, 0),
    }
}
/// Called with `mutex` held. Paints every buffer once; the picture never changes.
fn paintBuffers() void {
    const size = imageSize(format) orelse return;
    const key: u32 = @intCast(profile.current.passthroughKeyRgb);
    if (buffer_count == 0) {
        fill(own[0..size], format, key);
        return;
    }
    for (buffers[0..buffer_count]) |maybe| if (maybe) |ptr| {
        if (buffer_size >= size) fill(ptr[0..size], format, key);
    };
}

fn getCameraFrameDimensions(_: *Camera, f: Format, w: *u32, h: *u32) callconv(.c) bool {
    log(0, "GetCameraFrameDimensions format={d}", .{@intFromEnum(f)});
    if (imageSize(f) == null) return false;
    w.* = width;
    h.* = height;
    return true;
}
fn getCameraFrameBufferingRequirements(_: *Camera, queue: *i32, size: *u32) callconv(.c) bool {
    log(1, "GetCameraFrameBufferingRequirements", .{});
    queue.* = 3;
    size.* = width * height * 4;
    return true;
}
fn setCameraFrameBuffering(_: *Camera, count: i32, ptrs: ?[*]?*anyopaque, size: u32) callconv(.c) bool {
    log(2, "SetCameraFrameBuffering count={d} size={d} buffers={s}", .{ count, size, if (ptrs != null) "given" else "none" });
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (count < 0 or count > buffers.len) return false;
    buffer_count = 0;
    if (ptrs) |list| {
        for (0..@intCast(count)) |i| buffers[i] = @ptrCast(list[i]);
        buffer_count = @intCast(count);
    }
    buffer_size = size;
    paintBuffers();
    return true;
}
fn setCameraVideoStreamFormat(_: *Camera, f: Format) callconv(.c) bool {
    log(3, "SetCameraVideoStreamFormat format={d}", .{@intFromEnum(f)});
    if (imageSize(f) == null) return false;
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    format = f;
    paintBuffers();
    return true;
}
fn getCameraVideoStreamFormat(_: *Camera) callconv(.c) Format {
    log(4, "GetCameraVideoStreamFormat", .{});
    return format;
}
fn startVideoStream(_: *Camera) callconv(.c) bool {
    log(5, "StartVideoStream", .{});
    std.Io.Threaded.mutexLock(&mutex);
    if (streaming) {
        std.Io.Threaded.mutexUnlock(&mutex);
        return true;
    }
    streaming = true;
    paused = false;
    sequence = 0;
    current = null;
    start_ns = nowNs();
    paintBuffers();
    std.Io.Threaded.mutexUnlock(&mutex);
    stopping.store(false, .release);
    if (thread == null) thread = std.Thread.spawn(.{}, produce, .{}) catch {
        std.Io.Threaded.mutexLock(&mutex);
        streaming = false;
        std.Io.Threaded.mutexUnlock(&mutex);
        return false;
    };
    return true;
}
fn stopVideoStream(_: *Camera) callconv(.c) void {
    log(6, "StopVideoStream", .{});
    if (!queue_ready) {
        stop();
        return;
    }
    std.Io.Threaded.mutexLock(&mutex);
    streaming = false;
    current = null;
    std.Io.Threaded.mutexUnlock(&mutex);
}
pub fn stop() void {
    stopping.store(true, .release);
    if (thread) |t| t.join();
    thread = null;
    transport_queue.stop();
    queue_ready = false;
    std.Io.Threaded.mutexLock(&mutex);
    streaming = false;
    current = null;
    std.Io.Threaded.mutexUnlock(&mutex);
}
fn isVideoStreamActive(_: *Camera, p: ?*bool, elapsed: ?*f32) callconv(.c) bool {
    log(7, "IsVideoStreamActive", .{});
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    if (p) |out| out.* = paused;
    if (elapsed) |out| out.* = if (streaming) @floatCast(@as(f64, @floatFromInt(nowNs() - start_ns)) / 1e9) else 0;
    return streaming;
}
fn getVideoStreamFrame(_: *Camera) callconv(.c) ?*const Frame {
    log(8, "GetVideoStreamFrame", .{});
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    // Modern SteamVR reads the queue. Returning a public frame too makes its sink
    // repeatedly poll rejected data (also observed by openvr_camera_sim).
    if (queue_ready) return null;
    const ready = current;
    current = null;
    return if (ready) |i| &frames[i] else null;
}
fn releaseVideoStreamFrame(_: *Camera, _: ?*const Frame) callconv(.c) void {
    log(9, "ReleaseVideoStreamFrame", .{});
}
fn setAutoExposure(_: *Camera, on: bool) callconv(.c) bool {
    log(10, "SetAutoExposure {}", .{on});
    return true;
}
fn pauseVideoStream(_: *Camera) callconv(.c) bool {
    log(11, "PauseVideoStream", .{});
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    paused = true;
    return true;
}
fn resumeVideoStream(_: *Camera) callconv(.c) bool {
    log(12, "ResumeVideoStream", .{});
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    paused = false;
    return true;
}
fn getCameraDistortion(_: *Camera, camera: u32, u: f32, v: f32, ou: *f32, ov: *f32) callconv(.c) bool {
    log(13, "GetCameraDistortion camera={d}", .{camera});
    ou.* = u;
    ov.* = v;
    return camera == 0;
}
/// 90 degrees across, square pixels: focal length in pixels.
const focal: f32 = @as(f32, @floatFromInt(width)) / 2;
fn getCameraProjection(_: *Camera, camera: u32, kind: i32, near: f32, far: f32, out: *[4][4]f32) callconv(.c) bool {
    log(14, "GetCameraProjection camera={d} type={d} near={d} far={d}", .{ camera, kind, near, far });
    if (camera != 0) return false;
    out.* = @splat(@splat(0));
    out[0][0] = 2 * focal / @as(f32, @floatFromInt(width));
    out[1][1] = 2 * focal / @as(f32, @floatFromInt(height));
    out[2][2] = -(far + near) / (far - near);
    out[2][3] = -2 * far * near / (far - near);
    out[3][2] = -1;
    return true;
}
fn setFrameRate(_: *Camera, isp: i32, sensor: i32) callconv(.c) bool {
    log(15, "SetFrameRate isp={d} sensor={d}", .{ isp, sensor });
    return true;
}
fn setCameraVideoSinkCallback(_: *Camera, s: ?*Sink) callconv(.c) bool {
    log(16, "SetCameraVideoSinkCallback {s}", .{if (s != null) "set" else "cleared"});
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    sink = s;
    return true;
}
fn getCameraCompatibilityMode(_: *Camera, mode: *i32) callconv(.c) bool {
    log(17, "GetCameraCompatibilityMode", .{});
    mode.* = 0;
    return true;
}
fn setCameraCompatibilityMode(_: *Camera, mode: i32) callconv(.c) bool {
    log(18, "SetCameraCompatibilityMode {d}", .{mode});
    return true;
}
fn getCameraFrameBounds(_: *Camera, kind: i32, l: *u32, t: *u32, w: *u32, h: *u32) callconv(.c) bool {
    log(19, "GetCameraFrameBounds type={d}", .{kind});
    l.* = 0;
    t.* = 0;
    w.* = width;
    h.* = height;
    return true;
}
fn getCameraIntrinsics(_: *Camera, camera: u32, kind: i32, f: *[2]f32, c: *[2]f32, distortion: *i32, coefficients: *[8]f64) callconv(.c) bool {
    log(20, "GetCameraIntrinsics camera={d} type={d}", .{ camera, kind });
    if (camera != 0) return false;
    f.* = .{ focal, focal };
    c.* = .{ @as(f32, @floatFromInt(width)) / 2, @as(f32, @floatFromInt(height)) / 2 };
    distortion.* = 0; // VRDistortionFunctionType_None
    coefficients.* = @splat(0);
    return true;
}

/// Publishes a new frame (the same pixels) at `frame_rate` and notifies SteamVR's sink.
fn produce() void {
    const period = 1_000_000_000 / frame_rate;
    var next = nowNs();
    var queue_sequence: u32 = 0;
    while (!stopping.load(.acquire)) {
        std.Io.Threaded.mutexLock(&mutex);
        var notify: ?*Sink = null;
        if (streaming and !paused) if (imageSize(format)) |size| {
            const count = @max(buffer_count, 1);
            const index: usize = sequence % count;
            const data: [*]u8 = if (buffer_count == 0) &own else (buffers[index] orelse &own);
            const now = nowNs();
            frames[index] = .{
                .format = format,
                .width = width,
                .height = height,
                .imageDataSize = size,
                .frameSequence = sequence,
                .bufferIndex = @intCast(index),
                .bufferCount = @intCast(count),
                .frameElapsedTime = @as(f64, @floatFromInt(now - start_ns)) / 1e9,
                .frameDeliveryRate = @floatFromInt(frame_rate),
                .frameCaptureTicksServerAbsolute = now,
                .imageData = @intFromPtr(data),
            };
            current = index;
            sequence +%= 1;
            if (!queue_ready) notify = sink;
        };
        const publish = queue_ready and !paused;
        std.Io.Threaded.mutexUnlock(&mutex);
        if (publish) {
            transport_queue.publish(&queue_pixels, queue_sequence, nowNs());
            queue_sequence +%= 1;
        }
        if (notify) |s| {
            log(21, "sink callback", .{});
            s.vtable.callback(s);
        }
        next += period;
        const deadline: linux.timespec = .{ .sec = @intCast(next / 1_000_000_000), .nsec = @intCast(next % 1_000_000_000) };
        while (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &deadline, null)) == .INTR) {}
    }
}

test "key frames fill every supported format with the key colour" {
    var buf: [width * height * 4]u8 = undefined;
    fill(buf[0..imageSize(.rgb24).?], .rgb24, 0xff00ff);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255, 0, 255 }, buf[0..6]);
    fill(buf[0..imageSize(.rgbx32).?], .rgbx32, 0x00ff00);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, buf[0..4]);
    // Magenta in BT.601 limited range: Y 106, Cb 202, Cr 222.
    const yuv = ycbcr(0xff00ff);
    try std.testing.expectEqual([3]u8{ 106, 202, 222 }, yuv);
    const nv12 = imageSize(.nv12).?;
    fill(buf[0..nv12], .nv12, 0xff00ff);
    try std.testing.expectEqual(@as(u8, 106), buf[width * height - 1]);
    try std.testing.expectEqualSlices(u8, &.{ 202, 222 }, buf[width * height .. width * height + 2]);
    fill(buf[0..imageSize(.yuyv16).?], .yuyv16, 0xff00ff);
    try std.testing.expectEqualSlices(u8, &.{ 106, 202, 106, 222 }, buf[0..4]);
    try std.testing.expect(imageSize(.mjpeg) == null);
}
