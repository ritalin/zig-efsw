const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("c");

pub const Action = enum(c_uint) {
    Add = c.EFSW_ADD,
    Delete = c.EFSW_DELETE,
    Modified = c.EFSW_MODIFIED,
    Renamed = c.EFSW_MOVED,
};

pub const WatchId = c.efsw_watchid;
pub const WatchCallback = *const fn (watcher: *Self, watch_id: WatchId, dir_path: []const u8, basename: []const u8, user_data: ?*anyopaque) anyerror!void;
pub const MovedWatchCallback = *const fn (watcher: *Self, watch_id: WatchId, dir_path: []const u8, new_name: []const u8, old_name: []const u8, user_data: ?*anyopaque) anyerror!void;
pub const ErrorCallback = *const fn (watcher: *Self, watch_id: WatchId, action_tag: Action, error_tag: anyerror, user_data: ?*anyopaque) anyerror!void;

arena: *std.heap.ArenaAllocator,
instance: c.efsw_watcher,
watch_ids: std.StringHashMap(WatchId),
watch_contexts: std.AutoHashMap(WatchId, *WatchContext),

const Self = @This();

/// Creates a new file-watcher
pub fn init(allocator: std.mem.Allocator, use_generic_mode: bool) !Self {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);

    return .{
        .arena = arena,
        .instance = c.efsw_create(@intFromBool(use_generic_mode)),
        .watch_ids = std.StringHashMap(WatchId).init(allocator),
        .watch_contexts = std.AutoHashMap(WatchId, *WatchContext).init(allocator),
    };
}

/// Release the file-watcher and unwatch any directories
pub fn deinit(self: *Self) void {
    c.efsw_release(self.instance);

    self.watch_ids.deinit();
    self.watch_contexts.deinit();
    self.arena.deinit();
    self.arena.child_allocator.destroy(self.arena);
}

pub const AddWatchError = error {
    NotFound,
    Repeated,
    OutOfScope,
    NotReadable,
    Remote,
    WatchFailed,
    Unspecified,
    UnExpected,
};

pub const AddWatchOptions = struct {
    on_add: ?WatchCallback = null,
    on_delete: ?WatchCallback = null,
    on_modified: ?WatchCallback = null,
    on_renamed: ?MovedWatchCallback = null,
    on_error: ?ErrorCallback = null,
    recursive: bool = false,
    win_buffer_size: ?c_int = null,
    win_notify_filter: ?c_int = null,
    mac_modified_exclude_filter: MacModifiedExcludeFilters = .{},
    user_data: ?*anyopaque = null,
};

const MacModifiedFilterFlag = enum(u16) {
    // kFSEventStreamEventFlagItemFinderInfoMod
    finder_info = 0x2000,
    // kFSEventStreamEventFlagItemModified
    item = 0x1000,
    // kFSEventStreamEventFlagItemInodeMetaMod
    inode = 0x0400,
};
pub const MacModifiedExcludeFilters = std.enums.EnumFieldStruct(MacModifiedFilterFlag, bool, false);

pub fn isWatchng(self: *const Self, dir: []const u8) bool {
    return self.watch_ids.contains(dir);
}

/// Add a directory watch
pub fn addWatch(self: *Self, dir: []const u8, options: AddWatchOptions) anyerror!WatchId {
    if (self.watch_ids.contains(dir)) return error.Repeated;

    const allocator = self.arena.allocator();

    const context = try allocator.create(WatchContext);
    context.* = .{
        .allocator = allocator,
        .watcher = self,
        .dir = try allocator.dupe(u8, dir),
        .dir_sentinel = try allocator.dupeZ(u8, dir),
        .user_data = options.user_data,
        .on_add = options.on_add,
        .on_delete = options.on_delete,
        .on_modified = options.on_modified,
        .on_renamed = options.on_renamed,
        .on_error = options.on_error,
    };
    errdefer allocator.destroy(context);
    errdefer context.deinit();

    const id = try self.addWatchInternal(
        context.dir_sentinel, notifyChanged, context, 
        .{
            .recursive = options.recursive,
            .win_buffer_size = options.win_buffer_size,
            .win_notify_filter = options.win_notify_filter,
            .mac_modified_filter = filter: {
                switch (builtin.target.os.tag) {
                    inline .macos => {
                        var mask: c_int = 0;
                        var all: c_int = 0;
                        inline for (std.meta.fields(MacModifiedFilterFlag)) |field| {
                            if (@field(options.mac_modified_exclude_filter, field.name)) {
                                mask += field.value;
                            }
                            all += field.value;
                        }
                        break:filter if (mask > 0) all - mask else null;
                    },
                    inline else => { break:filter null; }
                }
            }
        }
    );
    try self.watch_ids.put(context.dir, id);
    try self.watch_contexts.put(id, context);

    return id;
}

/// Add a directory watch (low layer)
pub fn addWatchInternal(
    self: *Self, directory: [:0]const u8, callback: c.efsw_pfn_fileaction_callback, context: ?*anyopaque, 
    options: struct {
        recursive: bool = false,
        /// For Windows, the default buffer size of 63*1024 bytes sometimes is not enough and
        /// file system events may be dropped. For that, using a different (bigger) buffer size
        /// can be defined here, but note that this does not work for network drives,
        /// because a buffer larger than 64K will fail the folder being watched, see
        /// http://msdn.microsoft.com/en-us/library/windows/desktop/aa365465(v=vs.85).aspx)
        win_buffer_size: ?c_int,
        /// For Windows, per default all events are captured but we might only be interested
        /// in a subset; the value of the option should be set to a bitwise or'ed set of
        /// FILE_NOTIFY_CHANGE_* flags.
        win_notify_filter: ?c_int,
        /// For macOS (FSEvents backend), per default all modified event types are capture but we might
        // only be interested in a subset; the value of the option should be set to a set of bitwise
        // from:
        // kFSEventStreamEventFlagItemFinderInfoMod
        // kFSEventStreamEventFlagItemModified
        // kFSEventStreamEventFlagItemInodeMetaMod
        // Default configuration will set the 3 flags
        mac_modified_filter: ?c_int,
    }) AddWatchError!WatchId 
{
    var raw_options: [2]c.efsw_watcher_option = undefined;
    var options_count: usize = 0;

    if (comptime builtin.os.tag == .windows) {
        if (options.win_buffer_size) |win_buffer_size| {
            defer options_count += 1;
            raw_options[options_count] = .{ .option = c.EFSW_OPT_WIN_BUFFER_SIZE, .value = win_buffer_size };
        }
        if (options.win_notify_filter) |filter| {
            defer options_count += 1;
            raw_options[options_count] = .{ .option = c.EFSW_OPT_WIN_NOTIFY_FILTER, .value = filter };
        }
    }
    else if (comptime builtin.os.tag == .macos) {
        if (options.mac_modified_filter) |filter| {
            defer options_count += 1;
            raw_options[options_count] = .{ .option = c.EFSW_OPT_MAC_MODIFIED_FILTER, .value = filter };
        }
    }

    if (options_count == 0) {
        return handleErrUnion(c.efsw_addwatch(self.instance, directory.ptr, callback, @intFromBool(options.recursive), context));
    }
    else {
        return handleErrUnion(c.efsw_addwatch_withoptions(
            self.instance, directory.ptr, callback, @intFromBool(options.recursive), 
            raw_options[0..options_count].ptr, @intCast(options_count), 
            context,
            null
        ));
    }
}

fn handleErrUnion(id: c.efsw_watchid) AddWatchError!c.efsw_watchid {
    if (id >= 0) return id;

    return switch (id) {
        c.EFSW_NOTFOUND => error.NotFound,
        c.EFSW_REPEATED => error.Repeated,
        c.EFSW_OUTOFSCOPE => error.OutOfScope,
        c.EFSW_NOTREADABLE => error.NotReadable,
        c.EFSW_REMOTE => error.Remote,
        c.EFSW_WATCHER_FAILED => error.WatchFailed,
        c.EFSW_UNSPECIFIED => error.Unspecified,
        else => error.UnExpected,
    };
}

pub const RemoveCriteria = union(enum) {
    by_name: [:0]const u8,
    by_id: WatchId,
};

/// Remove a directory watch
pub fn removeWatch(self: *Self, id: WatchId) void {
    if (self.watch_contexts.fetchRemove(id)) |entry| {
        defer entry.value.deinit();
        defer _ = self.watch_ids.remove(entry.value.dir);

        self.removeWatchInternal(.{.by_id = id});
    }
}

/// Remove a directory watch (low layer)
pub fn removeWatchInternal(self: *Self, criteria: RemoveCriteria) void {
    switch (criteria) {
        .by_name => |directory| c.efsw_removewatch(self.instance, directory),
        .by_id => |id| c.efsw_removewatch_byid(self.instance, id),
    }
}

/// Starts watching
pub fn start(self: *Self) void {
    c.efsw_watch(self.instance);
}

/// Allow recursive watchers to follow symbolic links to other directories
pub fn followSymlink(self: *Self, following: bool) void {
    c.efsw_follow_symlinks(self.instance, @intFromBool(following));
}

/// If can follow symbolic links to directorioes
pub fn symlinkFollowed(self: *Self) bool {
    return c.efsw_follow_symlinks_isenabled(self.instance) != 0;    
}

const WatchContext = struct {
    allocator: std.mem.Allocator,
    watcher: *Self,
    dir: []const u8,
    dir_sentinel: [:0]const u8,
    user_data: ?*anyopaque,
    on_add: ?WatchCallback,
    on_delete: ?WatchCallback,
    on_modified: ?WatchCallback,
    on_renamed: ?MovedWatchCallback,
    on_error: ?ErrorCallback,

    pub fn deinit(context: *WatchContext) void {
        context.allocator.free(context.dir);
        context.allocator.free(context.dir_sentinel);
        context.allocator.destroy(context);
    }
};

fn notifyChanged(
    instance: c.efsw_watcher,
    watch_id: WatchId,
    dir_sentinel: [*c]const u8,
    filename_sentinel: [*c]const u8,
    action: c_uint,
    old_filename_sentinel: [*c]const u8,
    user_data: ?*anyopaque) callconv(.c) void 
{
    if (user_data == null) return;
    _ = instance;

    const context: *WatchContext = @ptrCast(@alignCast(user_data.?));
    const action_tag: Action = @enumFromInt(action);

    notifyChangedInternal(
        context, watch_id, action_tag,
        dir_sentinel, filename_sentinel, old_filename_sentinel, 
    )
    catch |err| {
        handle_error: {
            if (context.on_error) |f| {
                f(context.watcher, watch_id, action_tag, err, context.user_data) catch break:handle_error;

                return;
            }
        }

        @panic("Failed to handle error in watch callback");
    };
}

fn notifyChangedInternal(
    context: *WatchContext, watch_id: WatchId, action_tag: Action, 
    dir_sentinel: [*c]const u8,
    filename_sentinel: [*c]const u8,
    old_filename_sentinel: [*c]const u8) anyerror!void
{
    const dir_name = std.mem.span(dir_sentinel);
    const basename = std.mem.span(filename_sentinel);

    switch (action_tag) {
        .Add => {
            if (context.on_add) |f| {
                try f(context.watcher, watch_id, dir_name, basename, context.user_data);
            }
        },
        .Delete => {
            if (context.on_delete) |f| {
                try f(context.watcher, watch_id, dir_name, basename, context.user_data);
            }
        },
        .Modified => {
            if (context.on_modified) |f| {
                try f(context.watcher, watch_id, dir_name, basename, context.user_data);
            }
        },
        .Renamed => {
            if (context.on_renamed) |f| {
                const old_name: []const u8 = std.mem.span(old_filename_sentinel);
                try f(context.watcher, watch_id, dir_name, basename, old_name, context.user_data);
            }
        },
    }
}

pub const LastError = struct {
    pub fn get() []const u8 {
        return std.mem.span(c.efsw_getlasterror());
    }

    pub fn clear() void {
        c.efsw_clearlasterror();
    }
};

test "efsw wrapper test" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const QueueItem = struct {
        kind: enum {add, mod, del, mov},
        dir_path: []const u8,
        sub_path: []const u8,
        old_name: []const u8,

        pub const deinit = deintQueuetem;
    };

    fn deintQueuetem(self: *QueueItem, allocator: std.mem.Allocator) void {
        allocator.free(self.dir_path);
        allocator.free(self.sub_path);
        allocator.free(self.old_name);
    }

    const Queue = std.Io.Queue(QueueItem);

    const TestBed = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        active_kind: @FieldType(QueueItem, "kind") = .add, // TODO: because FSEvents has coalescing feature
        buffer: [32]QueueItem = undefined,
        q: Queue,

        pub fn init(io: std.Io, allocator: std.mem.Allocator) !*TestBed {
            const self = try allocator.create(TestBed);
            
            self.* = .{
                .io = io,
                .allocator = allocator,
                .q = Queue.init(&self.buffer),
            };

            return self;
        }

        pub fn deinit(self: *TestBed) void {
            self.q.close(self.io);
            self.allocator.destroy(self);
        }

        pub fn expectFileNew(self: *TestBed, dir: std.Io.Dir, path: []const u8) !void {
            act: {
                self.active_kind = .add;
                const file = try dir.createFile(self.io, path, .{});
                defer file.close(self.io);
                break:act;
            }

            const expect_path = try dir.realPathFileAlloc(self.io, path, self.allocator);
            defer self.allocator.free(expect_path);

            var item = try self.q.getOne(self.io);
            defer item.deinit(self.allocator);

            try std.testing.expectEqual(.add, item.kind);
            try std.testing.expectEqualStrings(std.fs.path.dirname(expect_path).?, item.dir_path);
            try std.testing.expectEqualStrings(std.fs.path.basename(expect_path), item.sub_path);
            try std.testing.expectEqualStrings("", item.old_name);
        }

        pub fn expectFileModifying(self: *TestBed, dir: std.Io.Dir, path: []const u8) !void {
            act: {
                self.active_kind = .mod;
                const file = try dir.openFile(self.io, path, .{.mode = .read_write});
                defer file.close(self.io);

                var buffer: [64]u8 = undefined;
                var writer = file.writer(self.io, &buffer);
                try writer.interface.writeAll("Hello world\n");
                try writer.interface.flush();
                break:act;
            }

            const expect_path = try dir.realPathFileAlloc(self.io, path, self.allocator);
            defer self.allocator.free(expect_path);

            var item = try self.q.getOne(self.io);
            defer item.deinit(self.allocator);

            try std.testing.expectEqual(.mod, item.kind);
            try std.testing.expectEqualStrings(std.fs.path.dirname(expect_path).?, item.dir_path);
            try std.testing.expectEqualStrings(std.fs.path.basename(expect_path), item.sub_path);
            try std.testing.expectEqualStrings("", item.old_name);
        }

        pub fn expectFileRename(self: *TestBed, dir: std.Io.Dir, path: []const u8, new_path: []const u8) !void {
            const old_path = try dir.realPathFileAlloc(self.io, path, self.allocator);
            defer self.allocator.free(old_path);

            act: {
                self.active_kind = .mov;
                try dir.rename(path, dir, new_path, self.io);
                break:act;
            }

            var item = try self.q.getOne(self.io);
            defer item.deinit(self.allocator);

        }

        pub fn expectFileDeleting(self: *TestBed, dir: std.Io.Dir, path: []const u8) !void {
            const expect_path = try dir.realPathFileAlloc(self.io, path, self.allocator);
            defer self.allocator.free(expect_path);

            act: {
                self.active_kind = .del;
                try dir.deleteFile(self.io, path);
                break:act;
            }

            var item = try self.q.getOne(self.io);
            defer item.deinit(self.allocator);

            try std.testing.expectEqual(.del, item.kind);
            try std.testing.expectEqualStrings(std.fs.path.dirname(expect_path).?, item.dir_path);
            try std.testing.expectEqualStrings(std.fs.path.basename(expect_path), item.sub_path);
            try std.testing.expectEqualStrings("", item.old_name);
        }

        fn notifyLifecycle(context: *TestBed, kind: @FieldType(QueueItem, "kind"), dir_path: []const u8, basename: []const u8, _: usize) !void {
            if (context.active_kind != kind) return;

            rec_result: {
                try context.q.putOne(context.io, .{
                    .kind = kind,
                    .dir_path = try context.allocator.dupe(u8, std.mem.trimEnd(u8, dir_path, std.fs.path.sep_str)),
                    .sub_path = try context.allocator.dupe(u8, std.mem.trimEnd(u8, basename, std.fs.path.sep_str)),
                    .old_name = "",
                });
                break:rec_result;
            }
        }

        fn notifyRename(context: *TestBed, dir_path: []const u8, basename: []const u8, old_name: []const u8) !void {
            if (context.active_kind != .mov) return;

            rec_result: {
                try context.q.putOne(context.io, .{
                    .kind = .mov,
                    .dir_path = try context.allocator.dupe(u8, std.mem.trimEnd(u8, dir_path, std.fs.path.sep_str)),
                    .sub_path = try context.allocator.dupe(u8, std.mem.trimEnd(u8, basename, std.fs.path.sep_str)),
                    .old_name = try context.allocator.dupe(u8, std.mem.trimEnd(u8, old_name, std.fs.path.sep_str)),
                });
                break:rec_result;
            }
        }
    };

    fn notifyEntryAdd(_: *Self, _: WatchId, dir_path: []const u8, basename: []const u8, user_data: ?*anyopaque) !void {
        var context: *TestBed = @ptrCast(@alignCast(user_data.?));
        return context.notifyLifecycle(.add, dir_path, basename, 10);
    }

    fn notifyEntryMod(_: *Self, _: WatchId, dir_path: []const u8, basename: []const u8, user_data: ?*anyopaque) !void {
        var context: *TestBed = @ptrCast(@alignCast(user_data.?));
        return context.notifyLifecycle(.mod, dir_path, basename, 20);
    }

    fn notifyEntryDel(_: *Self, _: WatchId, dir_path: []const u8, basename: []const u8, user_data: ?*anyopaque) !void {
        var context: *TestBed = @ptrCast(@alignCast(user_data.?));
        return context.notifyLifecycle(.del, dir_path, basename, 30);
    }

    fn notifyEntryRename(_: *Self, _: WatchId, dir_path: []const u8, new_name: []const u8, old_name: []const u8, user_data: ?*anyopaque) !void {
        var context: *TestBed = @ptrCast(@alignCast(user_data.?));
        return context.notifyRename(dir_path, new_name, old_name);
    }

    test "watch create/edit/rename/delete file" {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".",allocator);
        defer allocator.free(dir_path);

        var watcher = try Self.init(allocator, false);
        defer watcher.deinit();

        var testbed = try TestBed.init(io, allocator);
        defer testbed.deinit();

        _ = try watcher.addWatch(dir_path, .{
            .on_add = notifyEntryAdd,
            .on_modified = notifyEntryMod,
            .on_delete = notifyEntryDel,
            .on_renamed = notifyEntryRename,
            .mac_modified_exclude_filter = .{.inode = true, .finder_info = true},
            .user_data = testbed,
        });
        watcher.start();
        
        const file_name = "new_file";
        const renamed_file = "renamed_file";
        try testbed.expectFileNew(tmp_dir.dir, file_name);
        try testbed.expectFileModifying(tmp_dir.dir, file_name);
        try testbed.expectFileRename(tmp_dir.dir, file_name, renamed_file);
        try testbed.expectFileDeleting(tmp_dir.dir, renamed_file);
    }

    test "duplicate watch source" {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".",allocator);
        defer allocator.free(dir_path);

        var watcher = try Self.init(allocator, false);
        defer watcher.deinit();

        try std.testing.expectEqual(false, watcher.isWatchng(dir_path));

        _ = try watcher.addWatch(dir_path, .{
            .on_add = notifyEntryAdd,
            .on_modified = notifyEntryMod,
            .on_delete = notifyEntryDel,
            .on_renamed = notifyEntryRename,
            .mac_modified_exclude_filter = .{.inode = true, .finder_info = true},
        });

        try std.testing.expectEqual(true, watcher.isWatchng(dir_path));

        const err = watcher.addWatch(dir_path, .{
            .on_add = notifyEntryAdd,
            .on_modified = notifyEntryMod,
            .on_delete = notifyEntryDel,
            .on_renamed = notifyEntryRename,
            .mac_modified_exclude_filter = .{.inode = true, .finder_info = true},
        });
        try std.testing.expectError(error.Repeated, err);
    }
};