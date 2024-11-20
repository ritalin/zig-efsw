const std = @import("std");

pub const Watcher = @import("./Watcher.zig");

test "test entry point" {
    std.testing.refAllDecls(@This());
}