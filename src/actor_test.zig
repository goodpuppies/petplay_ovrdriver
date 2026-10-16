const std = @import("std");
const native = @import("actor.zig");
const a = std.testing.allocator;
fn init(actor: *native.Actor) !void {
    const response = (try actor.dispatch(a,
        \\{"kind":"message","data":{"address":{"fm":"SYSTEM","to":"WORKER"},"type":"INIT","payload":{"actorId":"driver@00000000-0000-0000-0000-000000000001","callbackKey":"key"}}}
    )).?;
    defer a.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "LOADED") != null);
}
test "invalid packet/envelope/order and size are rejected without poisoning session" {
    var actor: native.Actor = .{};
    try std.testing.expectError(error.UnexpectedEndOfInput, actor.dispatch(a, "{"));
    try std.testing.expectError(error.InvalidEnvelope, actor.dispatch(a, "{\"kind\":\"wat\"}"));
    const oversized = try a.alloc(u8, native.max_packet + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.PacketTooLarge, actor.dispatch(a, oversized));
    try std.testing.expectError(error.NotInitialized, actor.dispatch(a,
        \\{"kind":"message","data":{"address":{"fm":"test@x","to":"driver@x"},"type":"PING:123","payload":null}}
    ));
    try init(&actor);
    try std.testing.expectError(error.WrongActor, actor.dispatch(a,
        \\{"kind":"message","data":{"address":{"fm":"test@x","to":"wrong@x"},"type":"PING:123","payload":null}}
    ));
    const response = (try actor.dispatch(a,
        \\{"kind":"message","data":{"address":{"fm":"test@x","to":"driver@00000000-0000-0000-0000-000000000001"},"type":"PING:456","payload":null}}
    )).?;
    defer a.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "PING:456") != null);
}
test "fire and forget is silent; terminate detaches instead of exiting host" {
    var actor: native.Actor = .{};
    try init(&actor);
    try std.testing.expect((try actor.dispatch(a,
        \\{"kind":"message","data":{"address":{"fm":"test@x","to":"driver@00000000-0000-0000-0000-000000000001"},"type":"PING","payload":null}}
    )) == null);
    try std.testing.expect((try actor.dispatch(a, "{\"kind\":\"terminate\"}")) == null);
    try std.testing.expect(actor.close_requested);
}

test "controller commands reject unknown fields and remain inert when disabled" {
    var actor: native.Actor = .{};
    try init(&actor);
    for ([_][]const u8{
        \\{"mode":"sine","frequencyHz":0}
        ,
        \\{"mode":"sine","frequncyHz":1}
        ,
        \\{"mode":"sine","worldTranslationM":[0,1]}
        ,
        \\{"mode":"sine","worldTranslationM":[0,101,0]}
        ,
        \\{"mode":"sine","worldYawRad":4}
        ,
        \\{"mode":"other"}
    }) |payload| {
        const packet = try std.fmt.allocPrint(a, "{{\"kind\":\"message\",\"data\":{{\"address\":{{\"fm\":\"test@x\",\"to\":\"driver@00000000-0000-0000-0000-000000000001\"}},\"type\":\"SETCONTROLLERMOTION:test\",\"payload\":{s}}}}}", .{payload});
        defer a.free(packet);
        const response = (try actor.dispatch(a, packet)).?;
        defer a.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "__actorError") != null);
    }
    const response = (try actor.dispatch(a,
        \\{"kind":"message","data":{"address":{"fm":"test@x","to":"driver@00000000-0000-0000-0000-000000000001"},"type":"SETCONTROLLERMOTION:disabled","payload":{"mode":"sine"}}}
    )).?;
    defer a.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "ControllersDisabled") != null);
}
