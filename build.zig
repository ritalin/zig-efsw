const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib_efsw_core = b.addStaticLibrary(.{
        .name = "efsw_core",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_efsw_core.addIncludePath(b.path("./vendor/efsw/include"));
    lib_efsw_core.addIncludePath(b.path("./vendor/efsw/src"));
    lib_efsw_core.addCSourceFiles(.{
        .root = b.path("./vendor/efsw/src/efsw"),
        .files = &.{
            "Debug.cpp",
            "DirectorySnapshot.cpp",
            "DirectorySnapshotDiff.cpp",
            "DirWatcherGeneric.cpp",
            "FileInfo.cpp",
            "FileSystem.cpp",
            "FileWatcher.cpp",
            "FileWatcherCWrapper.cpp",
            "FileWatcherGeneric.cpp",
            "FileWatcherImpl.cpp",
            "Log.cpp",
            "Mutex.cpp",
            "String.cpp",
            "System.cpp",
            "Thread.cpp",
            "Watcher.cpp",
            "WatcherGeneric.cpp",
        },
        .flags = &.{"-std=c++20"},
    });

    lib_efsw_core.addCSourceFiles(.{
        .root = b.path("./vendor/efsw/src/efsw"),
        .files = switch (target.result.os.tag) {
            .windows => &.{
                "platform/win/FileSystemImpl.cpp",
                "platform/win/MutexImpl.cpp",
                "platform/win/SystemImpl.cpp",
                "platform/win/ThreadImpl.cpp",
            },
            else => &.{
                "platform/posix/FileSystemImpl.cpp",
                "platform/posix/MutexImpl.cpp",
                "platform/posix/SystemImpl.cpp",
                "platform/posix/ThreadImpl.cpp",
            }
        },
        .flags = &.{"-std=c++20"},
    });
    lib_efsw_core.addCSourceFiles(.{
        .root = b.path("./vendor/efsw/src/efsw"),
        .files = switch (target.result.os.tag) {
            .macos => &.{
		        "FileWatcherFSEvents.cpp",
		        "FileWatcherKqueue.cpp",
		        "WatcherFSEvents.cpp",
		        "WatcherKqueue.cpp",
            },
            .windows => &.{
		        "FileWatcherWin32.cpp",
		        "WatcherWin32.cpp",
            },
            .linux => &.{
		        "FileWatcherInotify.cpp",
		        "WatcherInotify.cpp",
            },
            .freebsd => &.{
		        "FileWatcherKqueue.cpp",
		        "WatcherKqueue.cpp",
            },
            else => &.{},
        },
        .flags = &.{"-std=c++20"},
    });

    if (target.result.os.tag == .macos) {
        lib_efsw_core.linkFramework("CoreFoundation");
        lib_efsw_core.linkFramework("CoreServices");
    }
    if (optimize == .Debug) {
        lib_efsw_core.root_module.addCMacro("DEBUG", "1");
    }

    lib_efsw_core.linkLibC();
    lib_efsw_core.linkLibCpp();
    lib_efsw_core.installHeader(b.path("./vendor/efsw/include/efsw/efsw.h"), "efsw/efsw.h");

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib_efsw_core);

    const mod_efsw = b.addModule("efsw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_efsw.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ b.install_path, "include" }) });
    mod_efsw.linkLibrary(lib_efsw_core);
}
