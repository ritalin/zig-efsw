const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_efsw_source = b.dependency("efsw_source", .{});

    const mod_efsw_binding = b.addTranslateC(.{
        .root_source_file = dep_efsw_source.path("include/efsw/efsw.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib_efsw_core = b.addLibrary(.{
        .name = "efsw_core",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    const efsw_source_root = dep_efsw_source.path("src/efsw");

    lib_efsw_core.root_module.addIncludePath(dep_efsw_source.path("include"));
    lib_efsw_core.root_module.addIncludePath(dep_efsw_source.path("src"));
    lib_efsw_core.root_module.addCSourceFiles(.{
        .root = efsw_source_root,
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
            "String.cpp",
            "System.cpp",
            "Watcher.cpp",
            "WatcherGeneric.cpp",
        },
        .flags = &.{"-std=c++23"},
    });

    lib_efsw_core.root_module.addCSourceFiles(.{
        .root = efsw_source_root,
        .files = switch (target.result.os.tag) {
            .windows => &.{
                "platform/win/FileSystemImpl.cpp",
                "platform/win/SystemImpl.cpp",
            },
            else => &.{
                "platform/posix/FileSystemImpl.cpp",
                "platform/posix/SystemImpl.cpp",
            }
        },
        .flags = &.{"-std=c++23"},
    });
    lib_efsw_core.root_module.addCSourceFiles(.{
        .root = efsw_source_root,
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
    if (optimize == .Debug) {
        lib_efsw_core.root_module.addCMacro("DEBUG", "1");
    }

    b.installArtifact(lib_efsw_core);

    const mod_efsw = b.addModule("efsw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = mod_efsw_binding.createModule() },
        },
    });
    mod_efsw.linkLibrary(lib_efsw_core);

    if (target.result.os.tag == .macos) {
        const sysroot: std.Build.LazyPath = .{
            .cwd_relative = b.graph.environ_map.get("SDKROOT").?
        };
        mod_efsw.addSystemFrameworkPath(sysroot.path(b, "System/Library/Frameworks"));
        
        mod_efsw.linkFramework("CoreFoundation", .{});
        mod_efsw.linkFramework("CoreServices", .{});
    }

    const test_efsw = b.addTest(.{
        .root_module = mod_efsw,
    });

    const run_lib_unit_tests = b.addRunArtifact(test_efsw);
    run_lib_unit_tests.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&b.addInstallArtifact(test_efsw, .{.dest_sub_path =  "../test/efsw_test"}).step);

    test_artifact: {
        test_step.dependOn(&b.addInstallArtifact(test_efsw, .{.dest_sub_path = b.pathJoin(&.{"../test/" ,test_efsw.name})}).step);
        break:test_artifact;
    }

}
