//! Linux dma-buf/sync_file inspection only. No wait and no imported consumer fence.
const std = @import("std");
const linux = std.os.linux;
const Export = extern struct { flags: u32 = 1, fd: i32 = -1 };
const Info = extern struct { name: [32]u8 = @splat(0), status: i32 = 0, flags: u32 = 0, count: u32 = 0, pad: u32 = 0, fences: u64 = 0 };
const Fence = extern struct { name: [32]u8 = @splat(0), driver: [32]u8 = @splat(0), status: i32 = 0, flags: u32 = 0, timestamp: u64 = 0 };
pub const Result = struct {
    exportErrno: u16 = 0,
    infoErrno: u16 = 0,
    status: i32 = 0,
    count: u32 = 0,
    active: u32 = 0,
    signaled: u32 = 0,
    errors: u32 = 0,
    truncated: bool = false,
    firstName: [32]u8 = @splat(0),
    firstDriver: [32]u8 = @splat(0),
    newestTimestampNs: u64 = 0,
};
pub fn inspect(fd: i32) Result {
    var result: Result = .{};
    var export_info: Export = .{};
    const exported = linux.ioctl(fd, 0xc0086202, @intFromPtr(&export_info));
    result.exportErrno = @intFromEnum(linux.errno(exported));
    if (result.exportErrno != 0 or export_info.fd < 0) return result;
    defer _ = linux.close(export_info.fd);
    var info: Info = .{};
    result.infoErrno = @intFromEnum(linux.errno(linux.ioctl(export_info.fd, 0xc0383e04, @intFromPtr(&info))));
    if (result.infoErrno != 0) return result;
    result.status = info.status;
    result.count = info.count;
    var fences: [16]Fence = @splat(.{});
    result.truncated = info.count > fences.len;
    info.count = @min(info.count, fences.len);
    info.fences = @intFromPtr(&fences);
    result.infoErrno = @intFromEnum(linux.errno(linux.ioctl(export_info.fd, 0xc0383e04, @intFromPtr(&info))));
    if (result.infoErrno != 0) return result;
    for (fences[0..@min(info.count, fences.len)], 0..) |f, i| {
        if (i == 0) {
            result.firstName = f.name;
            result.firstDriver = f.driver;
        }
        if (f.status == 0) result.active += 1 else if (f.status > 0) result.signaled += 1 else result.errors += 1;
        result.newestTimestampNs = @max(result.newestTimestampNs, f.timestamp);
    }
    return result;
}
pub fn layout(which: u32) usize {
    return switch (which) {
        0 => @sizeOf(Export),
        1 => @sizeOf(Info),
        2 => @sizeOf(Fence),
        3 => @offsetOf(Info, "fences"),
        else => 0,
    };
}
