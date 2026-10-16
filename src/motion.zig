//! Analytic ground truth independent of sampling cadence or frame count.
const std = @import("std");
const abi = @import("abi.zig");
pub const Config = struct {
    mode: enum { stationary, sine, sweep } = .stationary,
    frequencyHz: f64 = 0.7,
    positionAmplitudeM: f64 = 0.12,
    yawAmplitudeRad: f64 = 0.4,
    pub fn valid(self: Config) bool {
        return std.math.isFinite(self.frequencyHz) and self.frequencyHz > 0 and self.frequencyHz <= 5 and
            std.math.isFinite(self.positionAmplitudeM) and self.positionAmplitudeM >= 0 and self.positionAmplitudeM <= 1 and
            std.math.isFinite(self.yawAmplitudeRad) and self.yawAmplitudeRad >= 0 and self.yawAmplitudeRad <= std.math.pi;
    }
};
/// Constant-speed middle 80% of each leg; cosine velocity ramps reverse smoothly.
/// Units here are displacement normalized to [-1,1] and derivatives per second.
pub const Sweep = struct { value: f64, velocity: f64, acceleration: f64, constant_speed: bool, direction: f64 };
pub fn sweep(frequency_hz: f64, seconds: f64, hand: usize) Sweep {
    const phase = (seconds * frequency_hz + @as(f64, @floatFromInt(hand)) * 0.25);
    const cycle = phase - @floor(phase);
    const forward = cycle < 0.5;
    const t = if (forward) cycle * 2 else (cycle - 0.5) * 2;
    const ramp: f64 = 0.1;
    var distance: f64 = undefined;
    var speed: f64 = undefined;
    var acceleration: f64 = undefined;
    if (t < ramp) {
        const angle = std.math.pi * t / ramp;
        distance = 0.5 * (t - ramp / std.math.pi * @sin(angle));
        speed = 0.5 * (1 - @cos(angle));
        acceleration = 0.5 * std.math.pi / ramp * @sin(angle);
    } else if (t > 1 - ramp) {
        const u = t - (1 - ramp);
        const angle = std.math.pi * u / ramp;
        distance = t - ramp / 2 - 0.5 * (u - ramp / std.math.pi * @sin(angle));
        speed = 0.5 * (1 + @cos(angle));
        acceleration = -0.5 * std.math.pi / ramp * @sin(angle);
    } else {
        distance = t - ramp / 2;
        speed = 1;
        acceleration = 0;
    }
    const direction: f64 = if (forward) 1 else -1;
    const rate = 2 * frequency_hz;
    return .{ .value = direction * (2 * distance / (1 - ramp) - 1), .velocity = direction * 2 / (1 - ramp) * speed * rate, .acceleration = direction * 2 / (1 - ramp) * acceleration * rate * rate, .constant_speed = t >= ramp and t <= 1 - ramp, .direction = direction };
}
pub fn evaluate(config: Config, hand: usize, seconds: f64) abi.Pose {
    var pose: abi.Pose = .{ .vecPosition = .{ if (hand == 0) -0.25 else 0.25, 1.2, -0.5 } };
    if (config.mode == .stationary) return pose;
    if (config.mode == .sweep) {
        const point = sweep(config.frequencyHz, seconds, hand);
        pose.vecPosition[0] += config.positionAmplitudeM * point.value;
        pose.vecVelocity[0] = config.positionAmplitudeM * point.velocity;
        pose.vecAcceleration[0] = config.positionAmplitudeM * point.acceleration;
        const yaw = config.yawAmplitudeRad * point.value;
        pose.qRotation = .{ .w = @cos(yaw / 2), .y = @sin(yaw / 2) };
        pose.vecAngularVelocity[1] = config.yawAmplitudeRad * point.velocity;
        pose.vecAngularAcceleration[1] = config.yawAmplitudeRad * point.acceleration;
        return pose;
    }
    const omega = 2 * std.math.pi * config.frequencyHz;
    const phase = omega * seconds + (if (hand == 0) @as(f64, 0) else std.math.pi / 2.0);
    const sin = @sin(phase);
    const cos = @cos(phase);
    const yaw = config.yawAmplitudeRad * sin;
    pose.vecPosition[0] += config.positionAmplitudeM * sin;
    pose.vecVelocity[0] = config.positionAmplitudeM * omega * cos;
    pose.vecAcceleration[0] = -config.positionAmplitudeM * omega * omega * sin;
    pose.qRotation = .{ .w = @cos(yaw / 2), .y = @sin(yaw / 2) };
    pose.vecAngularVelocity[1] = config.yawAmplitudeRad * omega * cos;
    pose.vecAngularAcceleration[1] = -config.yawAmplitudeRad * omega * omega * sin;
    return pose;
}
test "analytic position and angular derivatives agree with independent finite differences" {
    const config: Config = .{ .mode = .sine };
    const dt = 0.00001;
    for (0..2) |hand| for ([_]f64{ 0, 0.13, 0.9, 3.2 }) |t| {
        const p = evaluate(config, hand, t);
        const before = evaluate(config, hand, t - dt);
        const after = evaluate(config, hand, t + dt);
        try std.testing.expectApproxEqAbs(p.vecVelocity[0], (after.vecPosition[0] - before.vecPosition[0]) / (2 * dt), 1e-8);
        try std.testing.expectApproxEqAbs(p.vecAcceleration[0], (after.vecVelocity[0] - before.vecVelocity[0]) / (2 * dt), 1e-8);
        const yaw_before = 2 * std.math.atan2(before.qRotation.y, before.qRotation.w);
        const yaw_after = 2 * std.math.atan2(after.qRotation.y, after.qRotation.w);
        try std.testing.expectApproxEqAbs(p.vecAngularVelocity[1], (yaw_after - yaw_before) / (2 * dt), 1e-8);
        try std.testing.expectApproxEqAbs(p.vecAngularAcceleration[1], (after.vecAngularVelocity[1] - before.vecAngularVelocity[1]) / (2 * dt), 1e-8);
    };
    try std.testing.expect(!Config.valid(.{ .frequencyHz = std.math.nan(f64) }));
    try std.testing.expect(!Config.valid(.{ .positionAmplitudeM = 2 }));
}

test "sweep has constant-rate opposite legs, smooth reversals and analytic derivatives" {
    const frequency: f64 = 0.35;
    const dt = 0.000001;
    for (0..2) |hand| for ([_]f64{ 0, 0.02, 0.17, 0.5, 0.8, 1.4, 1.5, 2, 2.84 }) |t| {
        const p = sweep(frequency, t, hand);
        const before = sweep(frequency, t - dt, hand);
        const after = sweep(frequency, t + dt, hand);
        try std.testing.expectApproxEqAbs(p.velocity, (after.value - before.value) / (2 * dt), 1e-7);
        try std.testing.expectApproxEqAbs(p.acceleration, (after.velocity - before.velocity) / (2 * dt), @as(f64, if (@abs(p.acceleration) < 1e-10) 3e-4 else 1e-5));
        try std.testing.expect(@abs(p.value) <= 1.00000001);
        if (p.constant_speed) try std.testing.expectApproxEqAbs(p.direction * 4 * frequency / 0.9, p.velocity, 1e-12);
        try std.testing.expectApproxEqAbs(p.value, sweep(frequency, t + 1 / frequency, hand).value, 1e-12);
    };
    for ([_]f64{ 0, 0.5 / frequency, 1 / frequency }) |t| {
        try std.testing.expectApproxEqAbs(@as(f64, 0), sweep(frequency, t, 0).velocity, 1e-10);
        try std.testing.expectApproxEqAbs(sweep(frequency, t - dt, 0).value, sweep(frequency, t + dt, 0).value, 1e-10);
    }
}
