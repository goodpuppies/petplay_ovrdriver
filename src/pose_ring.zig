//! Held head poses published to a shared file beside the control socket, so the media worker
//! can tag each captured frame with the head pose SteamVR rendered it for. Single writer
//! (callers serialize); each entry is a seqlock. Layout: docs in markdown/webxr-client.md.
const std = @import("std");
const linux = std.os.linux;
pub const magic: u32 = 0x50504850; // "PHPP" little-endian bytes: P H P P
pub const capacity = 64;
pub const entry_size = 64;
pub const file_size = 64 + capacity * entry_size;
/// `time_ns` is when the pose was latched for a frame; `held_ns` when it arrived from the client.
pub const Pose = struct { time_ns: u64, client_sequence: u64, rotation: [4]f32, position: [3]f32, held_ns: u64 = 0 };

pub const Ring = struct {
    bytes: []align(4096) u8,
    fn word(self: Ring, offset: usize) *u64 {
        return @ptrCast(@alignCast(&self.bytes[offset]));
    }
    pub fn init(bytes: []align(4096) u8) Ring {
        @memset(bytes[0..file_size], 0);
        std.mem.writeInt(u32, bytes[4..8], 1, .little);
        std.mem.writeInt(u32, bytes[8..12], capacity, .little);
        std.mem.writeInt(u32, bytes[12..16], entry_size, .little);
        const ring: Ring = .{ .bytes = bytes };
        // Magic last: a reader that sees it sees a complete header.
        @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(&bytes[0]))), magic, .release);
        return ring;
    }
    pub fn write(self: Ring, pose: Pose) void {
        const count = @atomicLoad(u64, self.word(16), .acquire);
        const base = 64 + @as(usize, @intCast(count % capacity)) * entry_size;
        const lock = self.word(base);
        const version = @atomicLoad(u64, lock, .monotonic);
        @atomicStore(u64, lock, version + 1, .release); // odd: being written
        std.mem.writeInt(u64, self.bytes[base + 8 ..][0..8], pose.time_ns, .little);
        std.mem.writeInt(u64, self.bytes[base + 16 ..][0..8], pose.client_sequence, .little);
        for (pose.rotation, 0..) |v, i| std.mem.writeInt(u32, self.bytes[base + 24 + i * 4 ..][0..4], @bitCast(v), .little);
        for (pose.position, 0..) |v, i| std.mem.writeInt(u32, self.bytes[base + 40 + i * 4 ..][0..4], @bitCast(v), .little);
        std.mem.writeInt(u64, self.bytes[base + 56 ..][0..8], pose.held_ns, .little);
        @atomicStore(u64, lock, version + 2, .release);
        @atomicStore(u64, self.word(16), count + 1, .release);
    }
};

/// Creates (or reuses) `hmd-poses` in the driver's private control directory.
pub fn open(directory_fd: i32) !Ring {
    const rc = linux.openat(directory_fd, "hmd-poses", .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.PoseRingOpen;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const size = std.mem.alignForward(usize, file_size, 4096);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.PoseRingSize;
    const mapped = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(mapped) != .SUCCESS) return error.PoseRingMap;
    const ptr: [*]align(4096) u8 = @ptrFromInt(mapped);
    return Ring.init(ptr[0..size]);
}

test "entries are written in order with even seqlock versions" {
    var storage: [8192]u8 align(4096) = undefined;
    const ring = Ring.init(&storage);
    try std.testing.expectEqual(magic, std.mem.readInt(u32, storage[0..4], .little));
    for (0..capacity + 3) |i| ring.write(.{ .time_ns = 1000 + i, .client_sequence = i, .rotation = .{ 0, 0.5, 0, 0.75 }, .position = .{ 1, 2, 3 } });
    try std.testing.expectEqual(@as(u64, capacity + 3), std.mem.readInt(u64, storage[16..24], .little));
    // The 67th write (index 66) wrapped into slot 2, whose lock has been written twice.
    const base = 64 + 2 * entry_size;
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, storage[base..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 1066), std.mem.readInt(u64, storage[base + 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.5))), std.mem.readInt(u32, storage[base + 28 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 3))), std.mem.readInt(u32, storage[base + 48 ..][0..4], .little));
}
