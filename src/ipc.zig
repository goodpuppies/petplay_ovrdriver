//! Externally owned native actor, Linux private Unix socket. No subprocess spawning.
const std = @import("std");
const linux = std.os.linux;
const native = @import("actor.zig");
const state = @import("state.zig");
const Cred = extern struct { pid: i32, uid: u32, gid: u32 };
pub const Server = struct {
    directory: [96:0]u8 = @splat(0),
    directory_len: usize = 0,
    directory_fd: i32 = -1,
    lock_fd: i32 = -1,
    listener: i32 = -1,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    actor: native.Actor = .{ .process_owner = "steamvr", .allow_init = false },
    pub fn setDirectory(self: *Server, path: []const u8) bool {
        if (self.thread != null or path.len == 0 or path.len >= self.directory.len or path.len + "/control.sock".len >= 108 or path[0] != '/') return false;
        @memcpy(self.directory[0..path.len], path);
        self.directory[path.len] = 0;
        self.directory_len = path.len;
        return true;
    }
    pub fn start(self: *Server) !void {
        if (self.thread != null) return error.AlreadyRunning;
        if (self.directory_len == 0) {
            const path = try std.fmt.bufPrint(&self.directory, "/run/user/{d}/petplay_ovrdriver", .{linux.geteuid()});
            self.directory_len = path.len;
            self.directory[path.len] = 0;
        }
        const mkdir = linux.mkdir(&self.directory, 0o700);
        if (linux.errno(mkdir) != .SUCCESS and linux.errno(mkdir) != .EXIST) return error.DirectoryUnavailable;
        const dir = try fd(linux.openat(linux.AT.FDCWD, &self.directory, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0));
        errdefer _ = linux.close(dir);
        const directory_stat = try stat(dir, "", linux.AT.EMPTY_PATH);
        if (directory_stat.uid != linux.geteuid() or directory_stat.mode & 0o777 != 0o700) return error.InsecureDirectory;
        const lock = try fd(linux.openat(dir, "owner.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600));
        errdefer _ = linux.close(lock);
        const lock_stat = try stat(lock, "", linux.AT.EMPTY_PATH);
        if (lock_stat.uid != linux.geteuid() or lock_stat.mode & linux.S.IFMT != linux.S.IFREG or lock_stat.mode & 0o777 != 0o600) return error.InsecureLock;
        if (linux.errno(linux.flock(lock, 2 | 4)) != .SUCCESS) return error.AlreadyRunning; // LOCK_EX|LOCK_NB
        var old: linux.Statx = undefined;
        const old_result = linux.statx(dir, "control.sock", linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .UID = true }, &old);
        if (linux.errno(old_result) == .SUCCESS) {
            if (old.mode & linux.S.IFMT != linux.S.IFSOCK or old.uid != linux.geteuid()) return error.UnexpectedSocketEntry;
            if (linux.errno(linux.unlinkat(dir, "control.sock", 0)) != .SUCCESS) return error.UnlinkFailed;
        } else if (linux.errno(old_result) != .NOENT) return error.StatFailed;
        var address: linux.sockaddr.un = .{ .path = @splat(0) };
        const path = try std.fmt.bufPrint(address.path[0 .. address.path.len - 1], "{s}/control.sock", .{self.directory[0..self.directory_len]});
        const listener = try fd(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0));
        errdefer _ = linux.close(listener);
        if (linux.errno(linux.bind(listener, @ptrCast(&address), @intCast(2 + path.len + 1))) != .SUCCESS) return error.BindFailed;
        errdefer _ = linux.unlinkat(dir, "control.sock", 0);
        if (linux.errno(linux.fchmodat(dir, "control.sock", 0o600)) != .SUCCESS) return error.ChmodFailed;
        if (linux.errno(linux.listen(listener, 1)) != .SUCCESS) return error.ListenFailed;
        self.actor = .{ .process_owner = "steamvr", .allow_init = false };
        try self.actor.establishIdentity();
        self.directory_fd = dir;
        self.lock_fd = lock;
        self.listener = listener;
        self.stopping.store(false, .release);
        errdefer {
            self.directory_fd = -1;
            self.lock_fd = -1;
            self.listener = -1;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        state.ipc_listening.store(true, .release);
    }
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        state.ipc_listening.store(false, .release);
        if (self.listener >= 0) _ = linux.close(self.listener);
        if (self.directory_fd >= 0) _ = linux.unlinkat(self.directory_fd, "control.sock", 0);
        if (self.lock_fd >= 0) _ = linux.close(self.lock_fd);
        if (self.directory_fd >= 0) _ = linux.close(self.directory_fd);
        self.listener = -1;
        self.lock_fd = -1;
        self.directory_fd = -1;
    }
    fn run(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            if (!self.wait(self.listener, linux.POLL.IN)) continue;
            const client = fd(linux.accept4(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC)) catch continue;
            defer _ = linux.close(client);
            var cred: Cred = undefined;
            var size: u32 = @sizeOf(Cred);
            if (linux.errno(linux.getsockopt(client, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred).ptr, &size)) != .SUCCESS or size != @sizeOf(Cred) or cred.uid != linux.geteuid()) continue;
            _ = state.ipc_sessions.fetchAdd(1, .monotonic);
            state.ipc_connected.store(true, .release);
            self.serve(client) catch {};
            state.ipc_connected.store(false, .release);
            self.actor.close_requested = false;
        }
    }
    fn serve(self: *Server, client: i32) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const hello = try native.encode(arena.allocator(), .{ .kind = "ready", .actorId = self.actor.id[0..self.actor.id_len], .protocol = 1, .ownership = "external" });
        try self.send(client, hello);
        var line: [native.max_packet]u8 = undefined;
        var length: usize = 0;
        var bytes: [4096]u8 = undefined;
        while (!self.stopping.load(.acquire) and !self.actor.close_requested) {
            if (!self.wait(client, linux.POLL.IN)) continue;
            const n = linux.recvfrom(client, &bytes, bytes.len, 0, null, null);
            if (linux.errno(n) == .AGAIN or linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS or n == 0) return;
            for (bytes[0..n]) |byte| {
                if (byte != '\n') {
                    if (length == line.len) return error.PacketTooLarge;
                    line[length] = byte;
                    length += 1;
                    continue;
                }
                var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer request_arena.deinit();
                const response = self.actor.dispatch(request_arena.allocator(), line[0..length]) catch {
                    try self.send(client, "{\"kind\":\"messageerror\",\"message\":\"Invalid native actor packet\"}");
                    length = 0;
                    continue;
                };
                if (response) |out| try self.send(client, out);
                length = 0;
                if (self.actor.close_requested) break;
            }
        }
    }
    fn wait(self: *Server, socket: i32, events: i16) bool {
        if (self.stopping.load(.acquire)) return false;
        var poll = [_]linux.pollfd{.{ .fd = socket, .events = events, .revents = 0 }};
        const result = linux.poll(&poll, 1, 50);
        return linux.errno(result) == .SUCCESS and result > 0;
    }
    fn send(self: *Server, client: i32, data: []const u8) !void {
        const deadline = monotonicMs() + 1000;
        for ([_][]const u8{ data, "\n" }) |part| {
            var offset: usize = 0;
            while (offset < part.len) {
                if (self.stopping.load(.acquire)) return error.Stopped;
                if (monotonicMs() >= deadline) return error.WriteTimeout;
                const n = linux.sendto(client, part[offset..].ptr, part.len - offset, linux.MSG.NOSIGNAL, null, 0);
                if (linux.errno(n) == .INTR) continue;
                if (linux.errno(n) == .AGAIN) {
                    _ = self.wait(client, linux.POLL.OUT);
                    continue;
                }
                if (linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailed;
                offset += n;
            }
        }
    }
};
fn fd(result: usize) !i32 {
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    return @intCast(result);
}
fn stat(dir: i32, path: [*:0]const u8, flags: u32) !linux.Statx {
    var result: linux.Statx = undefined;
    if (linux.errno(linux.statx(dir, path, flags, .{ .MODE = true, .TYPE = true, .UID = true }, &result)) != .SUCCESS) return error.StatFailed;
    if (!result.mask.MODE or !result.mask.TYPE or !result.mask.UID) return error.MissingStatFields;
    return result;
}
fn monotonicMs() i64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) return 0;
    return value.sec * 1000 + @divTrunc(value.nsec, 1000000);
}
