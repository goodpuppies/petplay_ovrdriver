const driver = @import("driver.zig");
const abi = @import("abi.zig");
const state = @import("state.zig");
comptime {
    _ = driver;
}
export fn pp_test_device() callconv(.c) *abi.Device {
    return driver.testDevice();
}
export fn pp_test_pose_size() callconv(.c) usize {
    return @sizeOf(abi.Pose);
}
export fn pp_test_pose_align() callconv(.c) usize {
    return @alignOf(abi.Pose);
}
export fn pp_test_pose_position_offset() callconv(.c) usize {
    return @offsetOf(abi.Pose, "vecPosition");
}
export fn pp_test_pose_result_offset() callconv(.c) usize {
    return @offsetOf(abi.Pose, "result");
}
export fn pp_test_ticks() callconv(.c) u64 {
    return state.ticks.load(.monotonic);
}
export fn pp_test_handle() callconv(.c) u64 {
    return state.handle.load(.acquire);
}
export fn pp_test_initialized() callconv(.c) bool {
    return state.initialized.load(.acquire);
}
export fn pp_test_standby() callconv(.c) bool {
    return state.standby.load(.acquire);
}
export fn pp_test_host_pose(index: u32) callconv(.c) void {
    driver.testHostPose(index);
}
export fn pp_test_host_add() callconv(.c) bool {
    return driver.testHostAdd();
}
export fn pp_test_set_directory(path: [*:0]const u8) callconv(.c) bool {
    return driver.transport.setDirectory(@import("std").mem.span(path));
}
export fn pp_test_ipc_listening() callconv(.c) bool {
    return state.ipc_listening.load(.acquire);
}

export fn pp_test_direct_layout(which: u32) callconv(.c) usize {
    return switch (which) {
        0 => @sizeOf(abi.SwapSet),
        1 => @sizeOf(abi.LayerEye),
        2 => @offsetOf(abi.LayerEye, "pose"),
        3 => @offsetOf(abi.LayerEye, "prediction"),
        else => 0,
    };
}

export fn pp_test_fence_layout(which: u32) callconv(.c) usize {
    return @import("fence_probe.zig").layout(which);
}
