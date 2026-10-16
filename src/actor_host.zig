//! Standalone native actor transport control, not the vrserver driver process.
const std = @import("std");
const actor_mod = @import("actor.zig");
fn send(bytes: []const u8) !void {
    for ([_][]const u8{ bytes, "\n" }) |part| {
        var offset: usize = 0;
        while (offset < part.len) {
            const n = std.os.linux.write(1, part[offset..].ptr, part.len - offset);
            if (std.os.linux.errno(n) == .INTR) continue;
            if (std.os.linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }
}
pub fn main() !void {
    var actor: actor_mod.Actor = .{};
    try send("{\"kind\":\"ready\"}");
    var line: [actor_mod.max_packet]u8 = undefined;
    var length: usize = 0;
    var dropping = false;
    var bytes: [4096]u8 = undefined;
    while (!actor.close_requested) {
        const count = std.os.linux.read(0, &bytes, bytes.len);
        if (count == 0) return;
        if (std.os.linux.errno(count) == .INTR) continue;
        if (std.os.linux.errno(count) != .SUCCESS) return error.ReadFailed;
        for (bytes[0..@intCast(count)]) |byte| {
            if (byte != '\n') {
                if (length == line.len) dropping = true;
                if (!dropping) {
                    line[length] = byte;
                    length += 1;
                }
                continue;
            }
            if (dropping) {
                try send("{\"kind\":\"messageerror\",\"message\":\"Packet exceeds 16384 bytes\"}");
            } else {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const response = actor.dispatch(arena.allocator(), line[0..length]) catch {
                    try send("{\"kind\":\"messageerror\",\"message\":\"Invalid native actor packet\"}");
                    length = 0;
                    continue;
                };
                if (response) |out| try send(out);
            }
            length = 0;
            dropping = false;
            if (actor.close_requested) break;
        }
    }
}
