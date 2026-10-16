const std = @import("std");
pub var initialized = std.atomic.Value(bool).init(false);
pub var standby = std.atomic.Value(bool).init(false);
pub var ticks = std.atomic.Value(u64).init(0);
pub var handle = std.atomic.Value(u64).init(0);
