const std = @import("std");
const efsw = @import("efsw");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var watcher = try efsw.Watcher.init(allocator, false);
    defer watcher.deinit();

    const root_dir = try std.fs.cwd().realpathAlloc(allocator, "./zig-out");
    defer allocator.free(root_dir);

    _ = try watcher.addWatch(
        root_dir,
        .{
            .on_add = notifyAdd,
            .on_delete = notifyDelete,
            .on_modified = notifyModified,
            .on_renamed = notifyMoved,
            .recursive = true,
        }
    );

    watcher.start();

    var svr = try std.zig.Server.init(.{
        .gpa = allocator,
        .in = std.io.getStdIn(),
        .out = std.io.getStdOut(),
        .zig_version = "<<no version>>\n",
    });
    defer svr.deinit();

    _ = try svr.receiveMessage();
}

fn notifyAdd(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, user_data: ?*anyopaque) void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Added/ id: {}, dir: {s}, name: {s}\n", .{id, dir, basename});
}

fn notifyDelete(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, user_data: ?*anyopaque) void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Removed/ id: {}, dir: {s}, name: {s}\n", .{id, dir, basename});
}

fn notifyModified(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, user_data: ?*anyopaque) void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Modified/ id: {}, dir: {s}, name: {s}\n", .{id, dir, basename});
}

fn notifyMoved(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, old_name: []const u8, user_data: ?*anyopaque) void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Renamed/ id: {}, dir: {s}, name: {s}, name(old: {s}\n", .{id, dir, basename, old_name});
}