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
        vsyncEvent: *const fn (*Host, f64) callconv(.c) void,
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

pub const settings_version = "IVRSettings_003";
pub const properties_version = "IVRProperties_001";
pub const display_legacy_version = "IVRDisplayComponent_002";
pub const display_version = "IVRDisplayComponent_003";
// Unused entries retain their pointer-sized slots; only typed methods may be called.
pub const Settings = extern struct {
    vtable: *const extern struct {
        errorName: usize,
        setBool: usize,
        setInt32: usize,
        setFloat: usize,
        setString: usize,
        getBool: *const fn (*Settings, [*:0]const u8, [*:0]const u8, ?*i32) callconv(.c) bool,
        getInt32: usize,
        getFloat: usize,
        getString: *const fn (*Settings, [*:0]const u8, [*:0]const u8, [*]u8, u32, ?*i32) callconv(.c) void,
    },
};
pub const PropertyWrite = extern struct {
    prop: i32,
    writeType: i32 = 0,
    setError: i32 = 0,
    buffer: *const anyopaque,
    size: u32,
    tag: u32,
    err: i32 = 0,
};
pub const Properties = extern struct {
    vtable: *const extern struct {
        readBatch: usize,
        writeBatch: *const fn (*Properties, u64, [*]PropertyWrite, u32) callconv(.c) i32,
        errorName: usize,
        container: *const fn (*Properties, u32) callconv(.c) u64,
    },
};
pub const Distortion = extern struct { red: [2]f32, green: [2]f32, blue: [2]f32 };
pub const Vector2 = extern struct { v: [2]f32 };
pub const Display = extern struct { vtable: *const DisplayMethods };
pub const DisplayMethods = extern struct {
    bounds: *const fn (*Display, *i32, *i32, *u32, *u32) callconv(.c) void,
    onDesktop: *const fn (*Display) callconv(.c) bool,
    realDisplay: *const fn (*Display) callconv(.c) bool,
    renderSize: *const fn (*Display, *u32, *u32) callconv(.c) void,
    viewport: *const fn (*Display, i32, *u32, *u32, *u32, *u32) callconv(.c) void,
    projection: *const fn (*Display, i32, *f32, *f32, *f32, *f32) callconv(.c) void,
    distortion: *const fn (*Display, i32, f32, f32) callconv(.c) Distortion,
    inverse: *const fn (*Display, *Vector2, i32, u32, f32, f32) callconv(.c) bool,
};

pub const virtual_display_version = "IVRVirtualDisplay_002";
pub const PresentInfo = extern struct { texture: u64, vsync: i32, frame: u64, vsync_time: f64 };
pub const VirtualDisplay = extern struct { vtable: *const VirtualDisplayMethods };
pub const VirtualDisplayMethods = extern struct {
    present: *const fn (*VirtualDisplay, *const PresentInfo, u32) callconv(.c) void,
    waitForPresent: *const fn (*VirtualDisplay) callconv(.c) void,
    timing: *const fn (*VirtualDisplay, *f32, *u64) callconv(.c) bool,
};

pub const plugin_version = "IVRCompositorPluginProvider_001";
pub const Plugin = extern struct { vtable: *const PluginMethods };
pub const PluginMethods = extern struct {
    init: *const fn (*Plugin, ?*Context) callconv(.c) i32,
    cleanup: *const fn (*Plugin) callconv(.c) void,
    versions: *const fn (*Plugin) callconv(.c) [*:null]const ?[*:0]const u8,
    component: *const fn (*Plugin, [*:0]const u8) callconv(.c) ?*anyopaque,
};
pub const log_version = "IVRDriverLog_001";
pub const DriverLog = extern struct {
    vtable: *const extern struct { log: *const fn (*DriverLog, [*:0]const u8) callconv(.c) void },
};

pub const input_version = "IVRDriverInput_004";
// Prefix through haptic creation, as declared in the pinned SDK.
pub const Input = extern struct {
    vtable: *const extern struct {
        createBoolean: *const fn (*Input, u64, [*:0]const u8, *u64) callconv(.c) i32,
        updateBoolean: *const fn (*Input, u64, bool, f64) callconv(.c) i32,
        createScalar: *const fn (*Input, u64, [*:0]const u8, *u64, i32, i32) callconv(.c) i32,
        updateScalar: *const fn (*Input, u64, f32, f64) callconv(.c) i32,
        createHaptic: *const fn (*Input, u64, [*:0]const u8, *u64) callconv(.c) i32,
    },
};

pub const direct_version = "IVRDriverDirectModeComponent_009";
pub const resource_version = "IVRIPCResourceManagerClient_003";
pub const SwapDesc = extern struct { width: u32, height: u32, format: u32, samples: u32 };
pub const SwapSet = extern struct { handles: [3]u64 = @splat(0), flags: u32 = 0 };
pub const LayerEye = extern struct {
    texture: u64,
    depth: u64,
    bounds: [4]f32,
    projection: [4][4]f32,
    pose: [3][4]f32,
    prediction: f32,
};
pub const Throttling = extern struct { frames: u32, predict: u32 };
pub const DirectTiming = extern struct { size: u32, presents: u32, mispresented: u32, dropped: u32, flags: u32 };
pub const Direct = extern struct { vtable: *const DirectMethods };
pub const DirectMethods = extern struct {
    create: *const fn (*Direct, u32, *const SwapDesc, *SwapSet) callconv(.c) void,
    destroy: *const fn (*Direct, u64) callconv(.c) void,
    destroyAll: *const fn (*Direct, u32) callconv(.c) void,
    next: *const fn (*Direct, *const [2]u64, *[2]u32) callconv(.c) void,
    submit: *const fn (*Direct, *const [2]LayerEye) callconv(.c) void,
    present: *const fn (*Direct, u64) callconv(.c) void,
    post: *const fn (*Direct, ?*const Throttling) callconv(.c) void,
    timing: *const fn (*Direct, *DirectTiming) callconv(.c) void,
};
pub const Resources = extern struct {
    vtable: *const extern struct {
        image: *const fn (*Resources, u32, u32, u32, bool, bool, bool, u32, u32, u32, u32, *u64) callconv(.c) bool,
        buffer: usize,
        semaphore: usize,
        ref: *const fn (*Resources, u64, ?*u64) callconv(.c) bool,
        unref: *const fn (*Resources, u64) callconv(.c) bool,
        formats: usize,
        modifiers: usize,
        import: usize,
        receiveFd: *const fn (*Resources, u64, *i32) callconv(.c) bool,
    },
};
