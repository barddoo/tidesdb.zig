const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_lz4 = b.option(bool, "lz4", "Enable LZ4 compression") orelse false;
    const with_zstd = b.option(bool, "zstd", "Enable Zstd compression") orelse false;
    const with_snappy = b.option(bool, "snappy", "Enable Snappy compression (requires libc++)") orelse false;

    const upstream = b.dependency("tidesdb", .{});

    const tidesdb = b.addLibrary(.{
        .name = "tidesdb",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    switch (target.result.os.tag) {
        .linux => tidesdb.root_module.addCMacro("_GNU_SOURCE", "1"),
        .freebsd => {
            tidesdb.root_module.addCMacro("__BSD_VISIBLE", "1");
            tidesdb.root_module.addCMacro("TIDESDB_HAVE_POSIX_FALLOCATE", "1");
        },
        .netbsd => {
            tidesdb.root_module.addCMacro("_NETBSD_SOURCE", "1");
            tidesdb.root_module.addCMacro("TIDESDB_HAVE_POSIX_FALLOCATE", "1");
        },
        .windows => tidesdb.root_module.addCMacro("__USE_MINGW_ANSI_STDIO", "1"),
        else => {},
    }

    tidesdb.root_module.addIncludePath(upstream.path("src"));
    tidesdb.root_module.addIncludePath(upstream.path("include"));
    tidesdb.root_module.addIncludePath(upstream.path("external"));
    tidesdb.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = tidesdb_srcs,
        .flags = cflags,
    });
    tidesdb.root_module.addCSourceFiles(.{
        .root = upstream.path("external"),
        .files = &.{"xxhash.c"},
        .flags = &.{"-w"},
    });

    if (with_lz4) {
        if (b.lazyDependency("lz4", .{ .target = target, .optimize = optimize })) |dep| {
            tidesdb.root_module.addCMacro("TIDESDB_HAVE_LZ4", "1");
            tidesdb.root_module.linkLibrary(dep.artifact("lz4"));
        }
    }
    if (with_zstd) {
        if (b.lazyDependency("zstd", .{ .target = target, .optimize = optimize })) |dep| {
            tidesdb.root_module.addCMacro("TIDESDB_HAVE_ZSTD", "1");
            tidesdb.root_module.linkLibrary(dep.artifact("zstd"));
        }
    }
    if (with_snappy) {
        if (b.lazyDependency("snappy", .{})) |dep| {
            tidesdb.root_module.addCMacro("TIDESDB_HAVE_SNAPPY", "1");
            tidesdb.root_module.linkLibrary(buildSnappy(b, dep, target, optimize));
        }
    }

    // Only the public surface is installed (db.h is self-contained), as upstream does.
    tidesdb.installHeadersDirectory(upstream.path("include"), "tidesdb", .{ .include_extensions = &.{".h"} });
    tidesdb.installHeader(upstream.path("external/xxhash.h"), "tidesdb/xxhash.h");
    b.installArtifact(tidesdb);

    // Smoke test: open a database, write, read back, close.
    const smoke = b.addExecutable(.{
        .name = "smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    smoke.root_module.addIncludePath(tidesdb.getEmittedIncludeTree());
    smoke.root_module.addCSourceFile(.{
        .file = b.path("test/smoke.c"),
        .flags = &.{"-std=c11"},
    });
    smoke.root_module.linkLibrary(tidesdb);

    const smoke_run = b.addRunArtifact(smoke);
    // Database directory inside the build cache. Its path is derived from the file contents,
    // so each combination of options gets its own database.
    const db_files = b.addWriteFiles();
    _ = db_files.add("backends", b.fmt("snappy={} lz4={} zstd={}\n", .{ with_snappy, with_lz4, with_zstd }));
    smoke_run.addDirectoryArg(db_files.getDirectory());
    // Expected backends, so the test fails if an option silently did nothing.
    smoke_run.addArgs(&.{
        if (with_snappy) "1" else "0",
        if (with_lz4) "1" else "0",
        if (with_zstd) "1" else "0",
    });
    const test_step = b.step("test", "Run Tests");
    test_step.dependOn(&smoke_run.step);
}

/// Google's Snappy has no Zig package, so build it here (the C API lives in snappy-c.cc).
fn buildSnappy(
    b: *Build,
    dep: *Build.Dependency,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Step.Compile {
    const t = target.result;
    const windows = t.os.tag == .windows;
    const posix = !windows;

    const config = b.addConfigHeader(.{
        .style = .{ .cmake = dep.path("cmake/config.h.in") },
        .include_path = "config.h",
    }, .{
        .HAVE_ATTRIBUTE_ALWAYS_INLINE = 1,
        .HAVE_BUILTIN_CTZ = 1,
        .HAVE_BUILTIN_EXPECT = 1,
        .HAVE_BUILTIN_PREFETCH = 1,
        .HAVE_FUNC_MMAP = @intFromBool(posix),
        .HAVE_FUNC_SYSCONF = @intFromBool(posix),
        .HAVE_LIBLZO2 = 0,
        .HAVE_LIBZ = 0,
        .HAVE_LIBLZ4 = 0,
        .HAVE_SYS_MMAN_H = @intFromBool(posix),
        .HAVE_SYS_RESOURCE_H = @intFromBool(posix),
        .HAVE_SYS_TIME_H = @intFromBool(posix),
        .HAVE_SYS_UIO_H = @intFromBool(posix),
        .HAVE_UNISTD_H = @intFromBool(posix),
        .HAVE_WINDOWS_H = @intFromBool(windows),
        // SIMD fast paths are left off so the build is portable across targets.
        .SNAPPY_HAVE_SSSE3 = 0,
        .SNAPPY_HAVE_X86_CRC32 = 0,
        .SNAPPY_HAVE_BMI2 = 0,
        .SNAPPY_HAVE_NEON = 0,
        .SNAPPY_RVV_1 = 0,
        .SNAPPY_RVV_0_7 = 0,
        .SNAPPY_HAVE_NEON_CRC32 = 0,
        .SNAPPY_IS_BIG_ENDIAN = @intFromBool(t.cpu.arch.endian() == .big),
    });
    const stubs = b.addConfigHeader(.{
        .style = .{ .cmake = dep.path("snappy-stubs-public.h.in") },
        .include_path = "snappy-stubs-public.h",
    }, .{
        .HAVE_SYS_UIO_H_01 = @intFromBool(posix),
        .PROJECT_VERSION_MAJOR = 1,
        .PROJECT_VERSION_MINOR = 3,
        .PROJECT_VERSION_PATCH = 1,
    });

    const lib = b.addLibrary(.{
        .name = "snappy",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    lib.root_module.addConfigHeader(config);
    lib.root_module.addConfigHeader(stubs);
    lib.root_module.addIncludePath(dep.path("."));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("."),
        .files = &.{ "snappy.cc", "snappy-c.cc", "snappy-sinksource.cc", "snappy-stubs-internal.cc" },
        .flags = &.{ "-std=c++17", "-DHAVE_CONFIG_H", "-DNDEBUG" },
    });
    lib.installHeader(dep.path("snappy-c.h"), "snappy-c.h");
    lib.installConfigHeader(stubs);
    return lib;
}

const cflags: []const []const u8 = &.{
    "-std=c11",
    "-D_FILE_OFFSET_BITS=64",
    "-Wno-unused-parameter",
    "-Wno-sign-compare",
    "-Wno-unused-function",
};

const tidesdb_srcs: []const []const u8 = &.{
    "base/alloc_fault.c",
    "base/arena.c",
    "base/bg_pool.c",
    "base/bg_ticker.c",
    "base/encoding/compress.c",
    "base/encoding/encoding.c",
    "base/errors.c",
    "base/lockfree.c",
    "base/log.c",
    "base/thread.c",
    "cache/cache.c",
    "column_family/cf_config.c",
    "column_family/cf_iter.c",
    "column_family/cf_registry.c",
    "column_family/column_family.c",
    "column_family/level/level_set.c",
    "compaction/compaction_commit.c",
    "compaction/compaction_exec.c",
    "compaction/compaction_planner.c",
    "datastructures/queue.c",
    "datastructures/skip_list/skip_list_core.c",
    "datastructures/skip_list/skip_list_cursor.c",
    "datastructures/skip_list/skip_list_node.c",
    "datastructures/skip_list/skip_list_read.c",
    "datastructures/skip_list/skip_list_write.c",
    "db.c",
    "engine/engine_backup.c",
    "engine/engine_cf_ops.c",
    "engine/engine_compaction.c",
    "engine/engine_iter.c",
    "engine/engine_l0.c",
    "engine/engine_ops.c",
    "engine/engine_prepared.c",
    "engine/engine_reaper.c",
    "engine/engine_recovery.c",
    "engine/engine_stats.c",
    "engine/engine_txn.c",
    "engine/engine.c",
    "fdmanager/fdmanager.c",
    "fdmanager/reaper.c",
    "flush/flush.c",
    "io/block_manager_core.c",
    "io/block_manager_cursor.c",
    "io/block_manager_fault.c",
    "io/block_manager_recover.c",
    "io/block_manager_util.c",
    "io/block_manager_write.c",
    "iter/merge_iter.c",
    "iter/merge_level_source.c",
    "iter/merge_sources.c",
    "manifest/manifest_api.c",
    "manifest/manifest_log.c",
    "manifest/manifest_record.c",
    "manifest/manifest_set.c",
    "memtable/backpressure.c",
    "memtable/l0_admission.c",
    "memtable/l0_immutable.c",
    "memtable/l0_read.c",
    "memtable/memtable.c",
    "range_tombstone/range_tombstone.c",
    "sstable/bloom_filter.c",
    "sstable/btree/btree_builder.c",
    "sstable/btree/btree_cursor.c",
    "sstable/btree/btree_node_encode.c",
    "sstable/btree/btree_node.c",
    "sstable/btree/btree_read.c",
    "sstable/partitioned_bloom_filter.c",
    "sstable/sstable_builder.c",
    "sstable/sstable_footer.c",
    "sstable/sstable_read.c",
    "sstable/sstable.c",
    "sstable/vlog_reclaim.c",
    "sstable/vlog_segment.c",
    "sstable/vlog.c",
    "threadmanager/threadmanager.c",
    "txn/cf_source.c",
    "txn/key_index.c",
    "txn/l0_adapter.c",
    "txn/mvcc_orphan.c",
    "txn/mvcc.c",
    "txn/prepare_stage.c",
    "txn/readset.c",
    "txn/registry.c",
    "txn/source.c",
    "txn/txn_commit.c",
    "txn/txn_two_phase.c",
    "txn/txn.c",
    "txn/wal_record.c",
    "txn/writeset.c",
};
