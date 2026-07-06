const std = @import("std");
const efsw = @import("efsw");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var watcher = try efsw.Watcher.init(allocator, false);
    defer watcher.deinit();

    const root_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, "./zig-out", allocator);
    defer allocator.free(root_dir);

    _ = watcher.addWatch(
        root_dir,
        .{
            .on_add = notifyAdd,
            .on_delete = notifyDelete,
            .on_modified = notifyModified,
            .on_renamed = notifyMoved,
            .on_error = notifyWatchError,
            .mac_modified_exclude_filter = .{.finder_info = true, .inode = true},
            .recursive = true,
        }
    )
    catch {
        std.debug.print("{s}", .{efsw.Watcher.LastError.get()});
    };

    watcher.start();

    var read_buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buffer);

    var write_buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &write_buffer);
    
    try writer.interface.writeAll("To exit, press Ctrl+C");

    var svr = try std.zig.Server.init(.{
        .in = &reader.interface,
        .out = &writer.interface,
        .zig_version = "<<no version>>\n",
    });

    _ = try svr.receiveMessage();
}

fn notifyAdd(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, user_data: ?*anyopaque) !void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Added/ id: {}, dir: {s}, name: {s}\n", .{id, dir, basename});
}

fn notifyDelete(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, user_data: ?*anyopaque) !void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Removed/ id: {}, dir: {s}, name: {s}\n", .{id, dir, basename});
}

fn notifyModified(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, user_data: ?*anyopaque) !void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Modified/ id: {}, dir: {s}, name: {s}\n", .{id, dir, basename});
}

fn notifyMoved(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, dir: []const u8, basename: []const u8, old_name: []const u8, user_data: ?*anyopaque) !void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Renamed/ id: {}, dir: {s}, name: {s}, name(old: {s}\n", .{id, dir, basename, old_name});
}

fn notifyWatchError(watcher: *efsw.Watcher, id: efsw.Watcher.WatchId, action_tag: efsw.Watcher.Action, err: anyerror, user_data: ?*anyopaque) !void {
    _ = watcher;
    _ = user_data;

    std.debug.print("Error/id: {}, error: {s}, action: {s}\n", .{id, @errorName(err), @tagName(action_tag)});
}
