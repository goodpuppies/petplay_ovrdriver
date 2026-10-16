const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const driver = b.addLibrary(.{ .name = "driver_petplay", .linkage = .dynamic, .root_module = b.createModule(.{ .root_source_file = b.path("src/driver.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    const install = b.addInstallFile(driver.getEmittedBin(), "petplay/bin/linux64/driver_petplay.so");
    b.getInstallStep().dependOn(&install.step);
    b.installFile("driver.vrdrivermanifest", "petplay/driver.vrdrivermanifest");
    const actor = b.addExecutable(.{ .name = "petplay_ovrdriver_actor", .root_module = b.createModule(.{ .root_source_file = b.path("src/actor_host.zig"), .target = target, .optimize = optimize }) });
    b.installArtifact(actor);
    const testlib = b.addLibrary(.{ .name = "petplay_abi_test", .linkage = .dynamic, .root_module = b.createModule(.{ .root_source_file = b.path("src/test_root.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    const consumer = b.addExecutable(.{ .name = "abi_consumer", .use_lld = true, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }) });
    consumer.root_module.addIncludePath(b.path("vendor/openvr"));
    consumer.root_module.addCSourceFiles(.{ .files = &.{"tests/abi_consumer.cpp"}, .flags = &.{ "-std=c++20", "-fno-rtti", "-UNDEBUG" } });
    b.installArtifact(consumer);
    b.installArtifact(testlib);
    const run = b.addRunArtifact(consumer);
    run.addFileArg(testlib.getEmittedBin());
    const test_step = b.step("test", "Validate pure Zig ABI with official-header C++ consumer (no SteamVR)");
    test_step.dependOn(&run.step);
    const protocol_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/actor_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_protocol = b.addRunArtifact(protocol_test);
    test_step.dependOn(&run_protocol.step);
    const transport_test = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tests/transport_test.py") });
    transport_test.addFileArg(actor.getEmittedBin());
    test_step.dependOn(&transport_test.step);
}
