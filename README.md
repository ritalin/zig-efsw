# zig-efsw

efsw: Entropia File System Watcher (https://github.com/SpartanJ/efsw) wrapper for Zig

`efsw` is directories watching library written by C++.
This package is wrapping it by Zig language.
This package has tested on MacOS (Ventura) only.

## Requirement

* Zig (https://ziglang.org/): version 0.14.0 or latter

## Installation

This package is depend on `efsw` as submodule.
So you can't use `zig fetch` command.
You need to add a clonining the repository.

```
cd $YOUR_REPOSITORY
git clone --recursive https://github.com/ritalin/zig-efsw $DEST_DIR
```

Then, add a dependency to `build.zig.zon`.

build.zig.zon:
```zig
.{
    // (snip)
    .dependencies = .{
        .zig_efsw = .{
            // $DEST_DIR is a cloned destination
            .path = $DEST_DIR
        },
    },
}
```

Finally, add to `build.zig`

build.zig:
```zig
const dep_efsw = b.dependency("zig_efsw", .{});
exe.root_module.addImport("efsw", dep_efsw.module("efsw"));
```

## Example

```zig
const std = @import("std");
const efsw = @import("efsw");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Instanciate watcher
    // If you wat to use a generic implementation, you can specify true for second arg.
    var watcher = try efsw.Watcher.init(allocator, false);
    defer watcher.deinit();

    const root_dir = try std.fs.cwd().realpathAlloc(allocator, "./zig-out");
    defer allocator.free(root_dir);

    // Register a watching directory
    _ = watcher.addWatch(
        root_dir,
        .{
            .on_add = notifyAdd,
            .on_delete = notifyDelete,
            .on_modified = notifyModified,
            .on_renamed = notifyMoved,
            .recursive = true,
        }
    )
    catch {
        std.debug.print("{s}", .{efsw.Watcher.LastError.get()});
    };

    // Start watch-session
    watcher.start();

    // This is hack for a infinite loop
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
```
