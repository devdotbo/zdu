# Research: zigdu - Fast Disk Usage Scanner

**Feature Branch**: `001-zigdu-core` | **Date**: 2026-02-13

## 1. Zig Language Version

- **Decision**: Zig 0.15.2 (latest stable, released 2025-10-12)
- **Rationale**: Latest stable release with critical I/O API improvements ("Writergate" overhaul), macOS compatibility fixes, and stable thread pool API
- **Alternatives considered**:
  - 0.14.0 (older, lacks I/O improvements)
  - 0.16.0-dev (unstable, breaking changes still in flux)
- **Key 0.15 changes affecting this project**:
  - Non-generic `std.Io.Reader` and `std.Io.Writer` replace generic interfaces
  - `std.fs.AtomicFile` now holds `File.Writer` instead of `File`
  - `async`/`await` keywords removed (not needed for this project)
  - `usingnamespace` removed
  - `BoundedArray` removed - use `ArrayListUnmanaged`

## 2. Directory Traversal Strategy

### Linux
- **Decision**: Use `std.fs.Dir.Iterator` (wraps `getdents64` internally)
- **Rationale**: Zig's standard `Dir.Iterator` already uses `getdents64` on Linux via the `nextLinux()` path. Direct syscall usage provides no benefit over the standard API since both make the same underlying call. The Iterator handles buffer management and dirent parsing.
- **Alternatives considered**:
  - Raw `std.os.linux.getdents64` - unnecessary complexity, no performance gain over std.fs.Dir.Iterator
  - io_uring getdents64 - experimental, not yet in stable Zig std

### macOS
- **Decision**: Use `getattrlistbulk()` via extern "c" declarations for cold scanning, `std.fs.Dir.Iterator` (wraps `__getdirentries64`) as fallback
- **Rationale**: `getattrlistbulk()` reads name + type + size in a single syscall per batch (vs readdir + stat = 2 syscalls per entry). For 15M files this halves the syscall count. Zig can call this via `extern "c" fn getattrlistbulk(...)` since Zig ships macOS libc headers.
- **Alternatives considered**:
  - `@cImport(@cInclude("sys/attr.h"))` - works but generates translation artifacts; manual extern declarations are cleaner
  - `searchfs()` - untested, catalog-level scan might be even faster but risky to depend on

### Reference implementation
- **wtfs** library (Ziggit, Sep 2025) implements `getattrlistbulk` in Zig for fast bulk stat on macOS

## 3. macOS APFS Cache Validation

- **Decision**: `getattrlist()` with `ATTR_CMNEXT_RECURSIVE_GENCOUNT` for per-subtree validation
- **Rationale**: A single syscall returns a uint64 generation counter that increments on any descendant modification. Comparing stored vs current gencount validates an entire subtree in microseconds. For `--depth 3` output, checking ~50-200 gencounts replaces walking millions of inodes.
- **Alternatives considered**:
  - Full rescan (too slow for warm path)
  - mtime-based delta scan (unreliable - doesn't detect all changes, misses metadata-only changes)
  - FSEvents watch mode (future enhancement, not needed for initial release)

## 4. Background Process Throttling

### macOS
- **Decision**: `setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)` for comprehensive background throttling
- **Rationale**: `PRIO_DARWIN_BG` sets scheduling priority to lowest, throttles disk I/O, and throttles network I/O - all in a single call. This is what `taskpolicy -b` uses internally. Available via libc: `extern "c" fn setpriority(c_int, c_uint, c_int) c_int`
- **Alternatives considered**:
  - `setiopolicy_np()` - more granular but `PRIO_DARWIN_BG` is simpler and covers all bases
  - `nice(20)` alone - does not throttle I/O

### Linux
- **Decision**: `nice(19)` + `ioprio_set(IOPRIO_WHO_PROCESS, 0, IOPRIO_PRIO_VALUE(IOPRIO_CLASS_IDLE, 0))`
- **Rationale**: Separate CPU and I/O priority on Linux. nice sets CPU scheduling, ioprio_set with IDLE class ensures background I/O does not interfere with foreground.
- **Alternatives considered**:
  - cgroups - too heavyweight for a user CLI tool

## 5. IPC and Session Management

- **Decision**: Unix domain sockets via `std.net.Stream` for status queries; PID files for process tracking
- **Rationale**: Unix domain sockets are the natural IPC mechanism on both platforms. Zig's `std.net` supports them. PID files at `~/.zigdu/cache/<hash>.pid` provide simple process lifecycle tracking.
- **Socket protocol**: Text-based commands over Unix socket at `~/.zigdu/cache/<hash>.sock`
  - `status` - returns JSON with progress, files scanned, ETA
  - `cancel` - graceful shutdown
  - `result` - current partial/complete results

## 6. Process Daemonization

- **Decision**: `std.process.Child` with stdout/stderr redirected to log file, parent exits after spawn
- **Rationale**: Zig's `std.process.Child` uses `posix_spawn` or `fork+exec` internally. The background scanner is spawned as a child process with detached I/O. The parent process (CLI) exits after printing the PID. Alternatively, direct `std.posix.fork()` + `std.c.setsid()` for full daemonization.
- **Alternatives considered**:
  - systemd/launchd integration - too heavyweight for first release
  - In-process background thread - ties the scan lifetime to the CLI process

## 7. Cache Format and Serialization

- **Decision**: Binary format with `extern struct` header, little-endian integers, variable-length path entries
- **Rationale**: Binary format achieves the 50ms retrieval target. `extern struct` (not `packed struct`) provides guaranteed field order and C-ABI-compatible layout. Little-endian is native to both target platforms (x86_64 and ARM64).
- **Header**: 32-byte extern struct (magic "ZGDU", version, timestamp, duration, entry count)
- **Entries**: 2-byte path length + path bytes + 8+4+4+1 = 17 bytes fixed fields
- **Reading strategy**:
  - Hot path (50ms target): `posix.mmap` with `PROT.READ`, `.TYPE = .PRIVATE`, `MADV.SEQUENTIAL` - zero-copy, no allocation
  - Cold path: `std.io.bufferedReader` for streaming reads
- **Writing strategy**: `std.fs.Dir.atomicFile` (write to temp, rename on finish) for atomic updates (FR-019)
- **Endianness**: `std.mem.nativeToLittle` / `std.mem.littleToNative` / `std.mem.readInt(T, bytes, .little)` / `writer.writeInt(T, val, .little)`

## 8. LRU Cache Eviction

- **Decision**: Filesystem mtime-based eviction (no separate index file)
- **Rationale**: Simpler and crash-safe. Update mtime on cache read via `file.updateTimes()`. On cache write, scan `~/.zigdu/cache/*.zgdu`, sort by mtime ascending, delete oldest until total size is under the configured cap (default 1 GB). This runs opportunistically (FR-023).
- **Alternatives considered**:
  - Separate index.bin file tracking access times - more complex, index can become stale/corrupt
  - In-memory LRU with periodic flush - lost on crash

## 9. Thread Pool for Parallel Traversal

- **Decision**: `std.Thread.Pool` with `spawnWg` for work groups
- **Rationale**: `std.Thread.Pool` is stable in Zig 0.15, used by the build system itself. `spawnWg` + `waitAndWork` provides clean work-group semantics for parallel directory traversal. Default to CPU count threads.
- **Pattern**: One work item per top-level subdirectory. Each worker recursively scans its subtree using `Dir.Iterator` (Linux) or `getattrlistbulk` (macOS).

## 10. Project Structure

- **Decision**: Single project with core module + two entry points (CLI and daemon)
- **Rationale**: Follows Zig community convention of core module + entry points. All shared scanning, caching, and IPC code lives in the core module. The CLI and daemon are thin entry points.
- **Build**: `build.zig` with conditional compilation via `builtin.os.tag` for platform-specific code. Link libc on macOS for `getattrlistbulk`/`getattrlist`/`setpriority`.
- **Testing**: Zig built-in test blocks alongside source code, with a separate test aggregation file.
