[![CI](https://github.com/barddoo/tidesdb-zig/actions/workflows/build.yml/badge.svg)](https://github.com/barddoo/tidesdb-zig/actions/workflows/build.yml)

# TidesDB

This is [TidesDB](https://github.com/tidesdb/tidesdb), packaged for [Zig](https://ziglang.org/).

## Installation

First, update your `build.zig.zon`:

```
# Initialize a `zig build` project if you haven't already
zig init
zig fetch --save git+https://github.com/barddoo/tidesdb.zig.git
```

You can then import `tidesdb` in your `build.zig` with:

```zig
const tidesdb_dependency = b.dependency("tidesdb", .{
    .target = target,
    .optimize = optimize,
});
your_exe.root_module.linkLibrary(tidesdb_dependency.artifact("tidesdb"));
```

Headers are installed under `tidesdb/`, e.g. `#include <tidesdb/db.h>`.

## Compression

No compression backends are built by default (only `TDB_COMPRESS_NONE`). Enable them with build options:

| Option     | Backend | Notes                                                                           |
| ---------- | ------- | ------------------------------------------------------------------------------- |
| `-Dlz4`    | LZ4     | via [allyourcodebase/lz4](https://github.com/allyourcodebase/lz4)               |
| `-Dzstd`   | Zstd    | via [allyourcodebase/zstd](https://github.com/allyourcodebase/zstd)             |
| `-Dsnappy` | Snappy  | built from [google/snappy](https://github.com/google/snappy); C++, links libc++ |

From a dependent project:

```zig
const tidesdb_dependency = b.dependency("tidesdb", .{
    .target = target,
    .optimize = optimize,
    .lz4 = true,
    .zstd = true,
    .snappy = true,
});
```

Backends are fetched lazily, so an option that is off downloads nothing. Check at runtime with
`tidesdb_compression_available(TDB_COMPRESS_LZ4)` and select one per column family through its
`encoding_pipeline`.
