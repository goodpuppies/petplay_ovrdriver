//! Deliberate Linux x86-64 C++ ABI subset; not a general C++ object system.
const builtin = @import("builtin");
comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64)
        @compileError("OpenVR driver ABI currently verified only on Linux x86-64");
}
pub const provider_version = "IServerTrackedDeviceProvider_004";
pub const device_version = "ITrackedDeviceServerDriver_005";
pub const host_version = "IVRServerDriverHost_006";
pub const interface_not_found: i32 = 105;
pub const driver_failed: i32 = 200;
pub const Quaternion = extern struct { w: f64 = 1, x: f64 = 0, y: f64 = 0, z: f64 = 0 };
pub const Pose = extern struct {
    poseTimeOffset: f64 = 0,
    qWorldFromDriverRotation: Quaternion = .{},
    vecWorldFromDriverTranslation: [3]f64 = @splat(0),
    qDriverFromHeadRotation: Quaternion = .{},
    vecDriverFromHeadTranslation: [3]f64 = @splat(0),
    vecPosition: [3]f64 = @splat(0),
    vecVelocity: [3]f64 = @splat(0),
    vecAcceleration: [3]f64 = @splat(0),
    qRotation: Quaternion = .{},
    vecAngularVelocity: [3]f64 = @splat(0),
    vecAngularAcceleration: [3]f64 = @splat(0),
    result: i32 = 200,
    poseIsValid: bool = true,
    willDriftInYaw: bool = false,
    shouldApplyHeadModel: bool = false,
    deviceIsConnected: bool = true,
};
pub const Context = extern struct {
    vtable: *const extern struct {
        getGenericInterface: *const fn (*Context, [*:0]const u8, ?*i32) callconv(.c) ?*anyopaque,
        getDriverHandle: *const fn (*Context) callconv(.c) u64,
    },
};
// Only the first two host methods are used. A prefix view of the supplied runtime vtable.
pub const Host = extern struct {
    vtable: *const extern struct {
        trackedDeviceAdded: *const fn (*Host, [*:0]const u8, i32, *Device) callconv(.c) bool,
        trackedDevicePoseUpdated: *const fn (*Host, u32, *const Pose, u32) callconv(.c) void,
    },
};
pub const ProviderMethods = extern struct {
    init: *const fn (*Provider, ?*Context) callconv(.c) i32,
    cleanup: *const fn (*Provider) callconv(.c) void,
    getInterfaceVersions: *const fn (*Provider) callconv(.c) [*:null]const ?[*:0]const u8,
    runFrame: *const fn (*Provider) callconv(.c) void,
    shouldBlockStandbyMode: *const fn (*Provider) callconv(.c) bool,
    enterStandby: *const fn (*Provider) callconv(.c) void,
    leaveStandby: *const fn (*Provider) callconv(.c) void,
};
pub const Provider = extern struct { vtable: *const ProviderMethods };
pub const DeviceMethods = extern struct {
    activate: *const fn (*Device, u32) callconv(.c) i32,
    deactivate: *const fn (*Device) callconv(.c) void,
    enterStandby: *const fn (*Device) callconv(.c) void,
    getComponent: *const fn (*Device, [*:0]const u8) callconv(.c) ?*anyopaque,
    debugRequest: *const fn (*Device, [*:0]const u8, [*]u8, u32) callconv(.c) void,
    getPose: *const fn (*Device) callconv(.c) Pose,
};
pub const Device = extern struct { vtable: *const DeviceMethods };
/// Itanium address point is at methods, after offset-to-top/typeinfo slots.
/// RTTI/dynamic_cast are outside our supported contract; typeinfo is null.
pub fn Table(comptime Methods: type) type {
    return extern struct { offset_to_top: isize = 0, typeinfo: ?*const anyopaque = null, methods: Methods };
}
