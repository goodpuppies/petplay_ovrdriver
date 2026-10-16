//! A separate provider instance loaded by vrcompositor, not vrserver.
const std = @import("std");
const abi = @import("abi.zig");
const sink = @import("virtual_display.zig");
var initialized = false;
pub var object: abi.Plugin = .{ .vtable = &table.methods };
const interfaces = [_:null]?[*:0]const u8{ abi.plugin_version, abi.virtual_display_version, abi.settings_version };
const table: abi.Table(abi.PluginMethods) = .{ .methods = .{ .init = init, .cleanup = cleanup, .versions = versions, .component = component } };
fn init(_: *abi.Plugin, context: ?*abi.Context) callconv(.c) i32 {
    if (initialized) return abi.driver_failed;
    const ctx = context orelse return abi.driver_failed;
    var err: i32 = 0;
    const raw = ctx.vtable.getGenericInterface(ctx, abi.settings_version, &err) orelse return abi.interface_not_found;
    if (err != 0) return err;
    const settings: *abi.Settings = @ptrCast(@alignCast(raw));
    if (!settings.vtable.getBool(settings, "driver_petplay", "syntheticHmd", &err) or err != 0) return abi.driver_failed;
    err = 0;
    if (settings.vtable.getBool(settings, "driver_petplay", "driverDirect", &err) and err == 0) return abi.driver_failed;
    err = 0;
    const log_raw = ctx.vtable.getGenericInterface(ctx, abi.log_version, &err);
    if (err == 0 and log_raw != null) {
        sink.logger = @ptrCast(@alignCast(log_raw.?));
        sink.logger.?.vtable.log(sink.logger.?, "PetPlay synthetic compositor plugin initialized");
    }
    sink.reset();
    initialized = true;
    return 0;
}
fn cleanup(_: *abi.Plugin) callconv(.c) void {
    if (sink.logger) |log| {
        var buffer: [192]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buffer, "PetPlay synthetic sink cleanup: presents={d}, waits={d}, timingQueries={d}", .{ sink.presents.load(.monotonic), sink.waits.load(.monotonic), sink.timing_queries.load(.monotonic) }) catch unreachable;
        log.vtable.log(log, message);
    }
    initialized = false;
    sink.logger = null;
}
fn versions(_: *abi.Plugin) callconv(.c) [*:null]const ?[*:0]const u8 {
    return &interfaces;
}
fn component(_: *abi.Plugin, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    return if (initialized and std.mem.eql(u8, std.mem.span(name), abi.virtual_display_version)) &sink.object else null;
}
