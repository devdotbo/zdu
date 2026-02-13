# Data Model: zigdu - Fast Disk Usage Scanner with Persistent Cache

**Feature Branch**: `001-zigdu-core` | **Date**: 2026-02-13 | **Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md)

---

## 1. Entity Overview

```
+------------------+        +------------------+        +------------------+
|   ScanResult     |        |   CacheEntry     |        |   VolumeInfo     |
|------------------|        |------------------|        |------------------|
| path             |------->| canonical_path   |        | mount_point      |
| timestamp        |        | version          |        | fs_type          |
| duration_ms      |        | header (32B)     |        | total_bytes      |
| volume_info -----+------->| entries (var)    |        | used_bytes       |
| root_entry ------+--+     | apfs_gencounts   |        | free_bytes       |
+------------------+  |     +------------------+        +------------------+
                      |
                      v
               +------------------+
               | DirectoryEntry   |
               |------------------|
               | path             |
               | size_bytes       |        +------------------+
               | file_count       |        | BackgroundSession|
               | dir_count        |        |------------------|
               | depth            |        | pid              |
               | children --------+--+     | target_path      |
               +------------------+  |     | state            |
                      ^              |     | pid_file_path    |
                      +--------------+     | socket_path      |
                      (recursive tree)     | progress         |
                                           | start_time       |
                                           | log_file_path    |
                                           +------------------+

               +------------------+
               |   Config         |
               |------------------|
               | base_dir         |
               | cache_dir        |
               | log_dir          |
               | max_cache_bytes  |
               | default_depth    |
               | default_top      |
               +------------------+
```

---

## 2. Entity Definitions

### 2.1 ScanResult

A snapshot of disk usage for a single filesystem path at a point in time. Produced by a foreground or background scan. Serialized to a `CacheEntry` for persistence.

| Field          | Type                | Description                                              |
|----------------|---------------------|----------------------------------------------------------|
| `path`         | `[]const u8`        | Canonical absolute real path that was scanned             |
| `timestamp`    | `i64`               | Unix epoch seconds when the scan completed                |
| `duration_ms`  | `u64`               | Wall-clock time of the scan in milliseconds               |
| `volume_info`  | `VolumeInfo`        | Volume-level capacity information for the scanned path    |
| `root_entry`   | `*DirectoryEntry`   | Root node of the directory entry tree                     |
| `entry_count`  | `u64`               | Total number of DirectoryEntry nodes in the tree          |

**Invariants**:
- `path` is always canonical: symlinks in parent components resolved, no trailing slash (except root `/`), absolute
- `timestamp` is always UTC
- `entry_count` equals the total number of nodes in the tree rooted at `root_entry` (including `root_entry` itself)

---

### 2.2 DirectoryEntry

A single node in the scan result tree, representing a directory with its cumulative size across all descendants.

| Field          | Type                | Size (binary) | Description                                              |
|----------------|---------------------|---------------|----------------------------------------------------------|
| `path`         | `[]const u8`        | 2B len + var  | Relative path from scan root (UTF-8, no null terminator) |
| `size_bytes`   | `u64`               | 8B            | Cumulative size of all descendant files in bytes          |
| `file_count`   | `u32`               | 4B            | Total count of regular files within this directory and all descendants |
| `dir_count`    | `u32`               | 4B            | Total count of subdirectories within this directory and all descendants |
| `depth`        | `u8`                | 1B            | Depth level relative to scan root (root = 0)              |
| `children`     | `[]DirectoryEntry`  | (in-memory)   | Child entries (not serialized; reconstructed from depth)  |

**Invariants**:
- `size_bytes` is the sum of all regular file sizes under this directory, recursively
- `file_count` is the total count of regular files within this directory and all descendants, recursively
- `dir_count` is the total count of subdirectories within this directory and all descendants, recursively
- `depth` is 0 for the scan root, 1 for its immediate children, and so on
- `path` uses forward slashes on all platforms
- Maximum `path` length is 65535 bytes (2-byte length prefix in binary format)
- Maximum `depth` is 255 (1-byte field in binary format)
- `children` is empty in the serialized form; the tree structure is reconstructed on read using `depth` values and entry ordering (depth-first pre-order)

**Path encoding**: Entries store paths relative to the scan root. For a scan of `/Users/bioharz`, the entry for `/Users/bioharz/Documents` stores `Documents`. The root entry stores an empty path (`path_len = 0`).

---

### 2.3 CacheEntry

A persisted `ScanResult` stored as a binary file on disk. Identified by the canonical path of the scanned directory.

| Field              | Type            | Description                                                    |
|--------------------|-----------------|----------------------------------------------------------------|
| `canonical_path`   | `[]const u8`    | Canonical absolute real path (identity key)                    |
| `file_path`        | `[]const u8`    | Path to the `.zgdu` file on disk                               |
| `version`          | `u32`           | Cache format version (current: 1)                              |
| `header`           | `CacheHeader`   | 32-byte binary header                                          |
| `entries`          | `[]CacheEntryRecord` | Variable-length binary entry records                     |
| `apfs_gencounts`   | `?[]ApfsGencount`   | Optional APFS generation counts per cached subtree (macOS only) |

**File naming**: The cache file is stored at `{cache_dir}/{path_hash}.zgdu` where `path_hash` is a 64-bit hash (SipHash or xxHash) of the canonical path, hex-encoded. Example: `~/.zigdu/cache/a1b2c3d4e5f67890.zgdu`.

**File locking**: Cache files are written atomically via `std.fs.Dir.atomicFile` (write to temp file, rename on completion). Readers never see partial writes. No advisory locks are needed.

**LRU tracking**: The file's filesystem `mtime` serves as the last-access timestamp. Reading a cache file updates `mtime` via `file.updateTimes()`. Eviction scans `*.zgdu` files, sorts by `mtime` ascending, and deletes the oldest until total size is under `max_cache_bytes`.

---

### 2.4 ApfsGencount

Per-subtree APFS generation count, stored alongside cache entries on macOS/APFS volumes. Used for fast cache validation without rescanning.

| Field          | Type            | Description                                                    |
|----------------|-----------------|----------------------------------------------------------------|
| `path`         | `[]const u8`    | Absolute path of the subtree root                              |
| `gencount`     | `u64`           | Value of `ATTR_CMNEXT_RECURSIVE_GENCOUNT` at scan time         |

**Validation flow**:
1. On cache hit, for each stored gencount entry, call `getattrlist()` with `ATTR_CMNEXT_RECURSIVE_GENCOUNT`
2. Compare stored `gencount` with current value
3. If equal, the subtree is unchanged - serve from cache
4. If different, rescan only that subtree and update the gencount

**Storage**: APFS gencounts are stored in a companion file `{path_hash}.gencount` alongside the `.zgdu` cache file. This keeps the core binary format platform-independent.

| Offset | Size | Field             | Description                                    |
|--------|------|-------------------|------------------------------------------------|
| 0      | 4B   | `magic`           | "GCNT" (0x47434E54)                            |
| 4      | 4B   | `entry_count`     | Number of gencount records                     |
| 8+     | var  | `records`         | Repeated: 2B path_len + path + 8B gencount     |

---

### 2.5 VolumeInfo

Filesystem-level capacity information for the volume containing the scanned path.

| Field          | Type            | Description                                              |
|----------------|-----------------|----------------------------------------------------------|
| `mount_point`  | `[]const u8`    | Filesystem mount point (e.g., `/`, `/Volumes/Data`)      |
| `fs_type`      | `FsType`        | Filesystem type enum                                     |
| `total_bytes`  | `u64`           | Total volume capacity in bytes                           |
| `used_bytes`   | `u64`           | Used space in bytes                                      |
| `free_bytes`   | `u64`           | Free space in bytes                                      |

**FsType enum**:

```
FsType = enum(u8) {
    apfs    = 1,
    hfsplus = 2,
    ext4    = 3,
    xfs     = 4,
    btrfs   = 5,
    other   = 255,
};
```

**Retrieval**: On macOS, use `statfs()`. On Linux, use `statvfs()`. The `fs_type` is derived from the filesystem type string (`f_fstypename` on macOS, `/proc/mounts` or `f_type` from `statfs` on Linux).

**Invariant**: `used_bytes + free_bytes <= total_bytes` (may not be exactly equal due to reserved blocks).

---

### 2.6 BackgroundSession

A running background scan process, tracked via PID file and Unix domain socket.

| Field            | Type            | Description                                                   |
|------------------|-----------------|---------------------------------------------------------------|
| `pid`            | `u32`           | OS process ID of the background scanner                       |
| `target_path`    | `[]const u8`    | Canonical absolute real path being scanned                    |
| `state`          | `SessionState`  | Current lifecycle state (see state transitions below)         |
| `pid_file_path`  | `[]const u8`    | Path to PID file: `{cache_dir}/{path_hash}.pid`               |
| `socket_path`    | `[]const u8`    | Path to Unix socket: `{cache_dir}/{path_hash}.sock`           |
| `progress`       | `ScanProgress`  | Current scan progress metrics                                 |
| `start_time`     | `i64`           | Unix epoch seconds when the session was started               |
| `log_file_path`  | `[]const u8`    | Path to session log: `{log_dir}/{path_hash}-{timestamp}.log`  |

**PID file format**: Plain text containing the PID as a decimal integer, followed by a newline. Example content: `48291\n`.

**PID file validation**: On startup, if a PID file exists, send signal 0 to the PID to check if the process is alive. If dead, clean up the stale PID file and socket file, then proceed. This handles crashed/killed processes.

**Socket protocol**: Text-based commands over the Unix domain socket:

| Command    | Response                                                        |
|------------|-----------------------------------------------------------------|
| `status`   | JSON: `{"status":"running","files_scanned":42000,"bytes_scanned":1234567890,"estimated_remaining_seconds":120,"percent_complete":68.4}` |
| `cancel`   | JSON: `{"status":"cancelled"}` then graceful shutdown           |
| `result`   | JSON: full scan result per [json-output.md](contracts/json-output.md) schema |

---

### 2.7 ScanProgress

Progress metrics for a running scan, reported via IPC.

| Field              | Type    | Description                                           |
|--------------------|---------|-------------------------------------------------------|
| `files_scanned`    | `u64`   | Number of filesystem entries processed so far          |
| `dirs_scanned`     | `u64`   | Number of directories entered so far                   |
| `bytes_scanned`    | `u64`   | Cumulative file sizes scanned so far                   |
| `errors_count`     | `u32`   | Number of inaccessible paths skipped                   |
| `estimated_remaining_seconds` | `?u32` | Estimated seconds remaining (null if not yet estimable) |
| `percent_complete` | `?f32`  | Percentage of scan completed (0.0-100.0), null if not yet estimable |

**ETA calculation**: Based on the ratio of `bytes_scanned` to the known volume used space, compute ETA as `(elapsed_seconds / fraction_complete) * (1 - fraction_complete)`. Report null when the estimate is not yet available.

---

### 2.8 Config

User-configurable settings, loaded from `~/.zigdu/config` (TOML-like key=value format).

| Field              | Type      | Default            | Description                                      |
|--------------------|-----------|--------------------|--------------------------------------------------|
| `base_dir`         | `[]const u8` | `~/.zigdu`      | Root directory for all zigdu data                 |
| `cache_dir`        | `[]const u8` | `{base_dir}/cache` | Directory for cache files                     |
| `log_dir`          | `[]const u8` | `{base_dir}/logs`  | Directory for background session logs         |
| `max_cache_bytes`  | `u64`     | 1073741824 (1 GB)  | Maximum total size of all cache files             |
| `default_depth`    | `u8`      | 3                  | Default `--depth` value when not specified        |
| `default_top`      | `u16`     | 20                 | Default `--top` value when not specified          |

**Config file format** (`~/.zigdu/config`):

```
cache_dir = /Users/bioharz/.zigdu/cache
log_dir = /Users/bioharz/.zigdu/logs
max_cache_bytes = 1073741824
default_depth = 3
default_top = 20
```

**Resolution order**: CLI flags override config file values, which override compiled defaults.

---

## 3. Entity Relationships

```
ScanResult 1------1 VolumeInfo
    |
    | contains
    |
ScanResult 1------1 DirectoryEntry (root)
                          |
                          | has children (recursive)
                          |
                     DirectoryEntry *

ScanResult 1------1 CacheEntry (serialized form)
                          |
                          | optionally has (macOS/APFS only)
                          |
                     ApfsGencount *

BackgroundSession 1------1 ScanResult (produced on completion)
BackgroundSession 1------1 ScanProgress (live metrics)
BackgroundSession *.....1 CacheEntry (writes to on completion)

Config 1------* CacheEntry (governs storage location and eviction)
Config 1------* BackgroundSession (governs log location)
```

**Cardinalities**:

| Relationship                          | Cardinality  | Notes                                                |
|---------------------------------------|-------------|------------------------------------------------------|
| ScanResult to VolumeInfo              | 1:1         | Each scan captures volume info once                  |
| ScanResult to DirectoryEntry (root)   | 1:1         | Exactly one root entry per scan                      |
| DirectoryEntry to DirectoryEntry      | 1:N (tree)  | Parent has zero or more children; each child has exactly one parent |
| ScanResult to CacheEntry              | 1:1         | One cache file per scan result                       |
| CacheEntry to ApfsGencount            | 1:N (0..N)  | Zero on non-APFS; one per cached subtree on APFS     |
| BackgroundSession to CacheEntry       | N:1         | Multiple sessions over time write to the same cache file (by path) |
| Config to CacheEntry                  | 1:N         | Config governs all cache entries                     |

---

## 4. State Transitions: BackgroundSession

```
                    spawn()
                      |
                      v
                 +---------+
                 |  idle    |   PID file created, socket bound
                 +---------+
                      |
                      | begin_scan()
                      v
                 +---------+
          +----->| scanning|   Traversing filesystem, updating progress
          |      +---------+
          |           |
          |    scan_complete()     cancel() or fatal error
          |           |                |
          |           v                v
          |    +------------+    +---------+
          |    | completing |    |  error  |   Log error, write partial results if any
          |    +------------+    +---------+
          |           |                |
          |    write_cache()           | cleanup()
          |           |                |
          |           v                v
          |      +---------+     +---------+
          |      |  done   |     | cleaned |   PID file removed, socket closed
          |      +---------+     +---------+
          |           |
          |  (if re-triggered by next CLI invocation)
          +-----------+
```

**State definitions**:

| State        | Description                                                        | Artifacts Present              |
|--------------|--------------------------------------------------------------------|--------------------------------|
| `idle`       | Process started, PID file written, socket listening, not yet scanning | PID file, socket               |
| `scanning`   | Actively traversing the filesystem tree                            | PID file, socket, log file     |
| `completing` | Scan finished, writing cache file atomically                       | PID file, socket, log file     |
| `done`       | Cache written successfully, ready for cleanup                      | PID file, socket, cache file, log file |
| `error`      | Scan failed (I/O error, volume unmounted, out of memory)           | PID file, socket, log file     |
| `cleaned`    | All session artifacts removed, process about to exit               | cache file (if done), log file |

**SessionState enum**:

```
SessionState = enum(u8) {
    idle       = 0,
    scanning   = 1,
    completing = 2,
    done       = 3,
    err        = 4,
    cleaned    = 5,
};
```

**Transition rules**:

| From         | To           | Trigger                                                    |
|--------------|--------------|------------------------------------------------------------|
| (none)       | `idle`       | Process spawned, PID file created, socket bound             |
| `idle`       | `scanning`   | `begin_scan()` called, traversal starts                     |
| `scanning`   | `completing` | All directories traversed, beginning cache write            |
| `scanning`   | `error`      | Fatal I/O error, volume unmounted, or `cancel` received     |
| `completing` | `done`       | Cache file written and renamed atomically                   |
| `completing` | `error`      | Cache write failed (disk full, permission denied)           |
| `done`       | `cleaned`    | PID file and socket removed, process exits with code 0      |
| `error`      | `cleaned`    | PID file and socket removed, process exits with non-zero code |

**Illegal transitions**: No state may transition backward. The `scanning` state cannot return to `idle`. The `done` state cannot return to `scanning` within the same process (a new process is spawned for re-scans).

---

## 5. Binary Cache Format Specification

### 5.1 Overview

Cache files use a compact binary format optimized for memory-mapped reads. All multi-byte integers are **little-endian**. The file extension is `.zgdu`.

```
+==========================+
|  CacheHeader (32 bytes)  |
+==========================+
|  Entry 0                 |
+--------------------------+
|  Entry 1                 |
+--------------------------+
|  ...                     |
+--------------------------+
|  Entry N-1               |
+==========================+
```

### 5.2 CacheHeader (32 bytes)

| Offset | Size | Field             | Type    | Description                                      |
|--------|------|-------------------|---------|--------------------------------------------------|
| 0      | 4B   | `magic`           | `[4]u8` | ASCII "ZGDU" (0x5A, 0x47, 0x44, 0x55)           |
| 4      | 4B   | `version`         | `u32`   | Format version (current: 1)                      |
| 8      | 8B   | `timestamp`       | `i64`   | Scan completion time as Unix epoch seconds (UTC) |
| 16     | 8B   | `scan_duration_ms`| `u64`   | Wall-clock scan duration in milliseconds         |
| 24     | 8B   | `entry_count`     | `u64`   | Number of DirectoryEntry records that follow     |

**Zig struct** (extern for guaranteed layout):

```zig
const CacheHeader = extern struct {
    magic: [4]u8,            // "ZGDU"
    version: u32,            // 1
    timestamp: i64,          // Unix epoch seconds
    scan_duration_ms: u64,   // milliseconds
    entry_count: u64,        // number of entries
};

comptime {
    std.debug.assert(@sizeOf(CacheHeader) == 32);
}
```

### 5.3 Entry Record (variable length)

Each entry is serialized contiguously after the header. Entries are ordered in **depth-first pre-order** (parent before children, left to right).

| Offset (relative) | Size    | Field        | Type      | Description                                    |
|--------------------|---------|--------------|-----------|------------------------------------------------|
| 0                  | 2B      | `path_len`   | `u16`     | Length of path string in bytes                 |
| 2                  | `path_len` | `path`    | `[path_len]u8` | Relative path from scan root (UTF-8)      |
| 2 + path_len      | 8B      | `size_bytes` | `u64`     | Cumulative size of all descendants in bytes    |
| 10 + path_len     | 4B      | `file_count` | `u32`     | Total descendant file count (recursive)        |
| 14 + path_len     | 4B      | `dir_count`  | `u32`     | Total descendant directory count (recursive)   |
| 18 + path_len     | 1B      | `depth`      | `u8`      | Depth level (0 = scan root)                    |

**Entry size**: `2 + path_len + 8 + 4 + 4 + 1 = 19 + path_len` bytes.

**Fixed fields per entry**: 17 bytes (size_bytes + file_count + dir_count + depth) plus 2-byte length prefix = 19 bytes overhead.

### 5.4 Tree Reconstruction from Flat Entries

The serialized format is a flat list, not a nested structure. The tree is reconstructed on read using depth values and entry ordering.

**Algorithm**:

```
stack = []
for each entry in entries:
    while stack is not empty and stack.top().depth >= entry.depth:
        stack.pop()
    if stack is not empty:
        stack.top().add_child(entry)
    else:
        // entry is root
    stack.push(entry)
```

This works because entries are in depth-first pre-order. An entry at depth D is a child of the most recent entry at depth D-1 still on the stack.

### 5.5 Volume Info Encoding

Volume info is **not** stored in the `.zgdu` cache file. It is retrieved fresh on each invocation via `statfs()`/`statvfs()` because volume capacity changes frequently (files created/deleted between scans). Storing stale free/used values would be misleading.

### 5.6 Size Estimates

For a scan with 15 million entries and an average path length of 30 bytes:

- Header: 32 bytes
- Per entry: 19 + 30 = 49 bytes average
- Total: 32 + (15,000,000 * 49) = ~700 MB

To meet the <500 MB target (from spec assumptions), paths should be stored relative to the scan root (reducing average path length) and common prefixes should be short. With an average relative path of 20 bytes, total is ~425 MB.

### 5.7 Reading Strategy

| Path         | Method                                                                 | Use Case                   |
|--------------|------------------------------------------------------------------------|-----------------------------|
| Hot (cached) | `posix.mmap` with `PROT.READ`, `.TYPE = .PRIVATE`, `MADV.SEQUENTIAL`  | Display cached results <50ms |
| Cold (scan)  | `std.io.bufferedReader` for streaming reads                            | Initial cache load           |

**mmap approach**: Map the entire file, cast header pointer, iterate entries by advancing a byte pointer. Zero allocation, zero copy. The OS pages in data on demand.

### 5.8 Writing Strategy

1. Open a temporary file via `std.fs.Dir.atomicFile()`
2. Write header with `entry_count = 0` (placeholder)
3. Write all entries sequentially using `writer.writeInt(T, val, .little)` for integers and `writer.writeAll()` for path bytes
4. Seek back to header offset, overwrite `entry_count` with actual count
5. Call `finish()` on the atomic file (renames temp to final path)

This ensures readers never see partial data (FR-019).

### 5.9 Versioning and Compatibility

| Version | Description                        | Action on Mismatch                    |
|---------|------------------------------------|---------------------------------------|
| 1       | Initial format (this document)     | N/A                                   |
| future  | Extended fields, new entry layout  | Discard cache, perform fresh scan     |

When the `version` field does not match the expected value, the cache file is treated as invalid. The tool logs a warning (if `--verbose`) and falls back to a fresh scan, overwriting the old file.

When the `magic` field is not "ZGDU", the file is treated as corrupt. Same behavior as version mismatch.

---

## 6. Validation Rules

### 6.1 Cache File Validation

| Rule ID | Check                                              | On Failure                              |
|---------|----------------------------------------------------|-----------------------------------------|
| V-001   | `magic` equals "ZGDU"                              | Treat as corrupt, discard and rescan    |
| V-002   | `version` equals expected version (currently 1)    | Treat as incompatible, discard and rescan |
| V-003   | `timestamp` is a positive integer and <= current time | Treat as corrupt, discard and rescan |
| V-004   | `entry_count` > 0                                  | Treat as empty/corrupt, discard and rescan |
| V-005   | File size >= 32 + sum of all entry sizes            | Treat as truncated, discard and rescan  |
| V-006   | Each `path_len` <= 65535 and does not extend past EOF | Treat as corrupt, discard and rescan |
| V-007   | Each `depth` value is consistent (no jump > parent.depth + 1) | Treat as corrupt, discard and rescan |
| V-008   | First entry has `depth` == 0                       | Treat as corrupt, discard and rescan    |

### 6.2 Path Canonicalization

| Rule ID | Check                                              | Action                                  |
|---------|----------------------------------------------------|-----------------------------------------|
| V-010   | Path is absolute (starts with `/`)                 | If relative, resolve against CWD        |
| V-011   | Symlinks in parent components are resolved          | Use `std.fs.realpath()` on parent       |
| V-012   | Trailing slashes removed (except root `/`)          | Strip trailing `/`                      |
| V-013   | `.` and `..` components resolved                   | Use `std.fs.realpath()`                 |
| V-014   | Path is valid UTF-8                                | Reject with error if not                |

### 6.3 Background Session Validation

| Rule ID | Check                                              | Action                                  |
|---------|----------------------------------------------------|-----------------------------------------|
| V-020   | PID file exists and contains valid integer          | If invalid, delete PID file             |
| V-021   | Process with PID is alive (signal 0 check)          | If dead, clean up PID file and socket   |
| V-022   | Socket file exists and is connectable               | If not, clean up stale socket file      |
| V-023   | No duplicate session for same canonical path        | Refuse to spawn, report existing PID    |

### 6.4 Config Validation

| Rule ID | Check                                              | Action                                  |
|---------|----------------------------------------------------|-----------------------------------------|
| V-030   | `max_cache_bytes` >= 10 MB (10485760)               | Clamp to minimum with warning           |
| V-031   | `default_depth` >= 1 and <= 255                     | Clamp to range with warning             |
| V-032   | `default_top` >= 1 and <= 65535                     | Clamp to range with warning             |
| V-033   | `cache_dir` and `log_dir` are writable              | Error on startup if not                 |

---

## 7. File System Layout

```
~/.zigdu/
  config                              # User configuration (key=value)
  cache/
    a1b2c3d4e5f67890.zgdu             # Binary cache file (ScanResult for some path)
    a1b2c3d4e5f67890.gencount         # APFS gencount companion (macOS only)
    a1b2c3d4e5f67890.pid              # PID file for active background session
    a1b2c3d4e5f67890.sock             # Unix domain socket for active session
    f9e8d7c6b5a43210.zgdu             # Another cached path
    ...
  logs/
    a1b2c3d4e5f67890-1707840000.log   # Session log: {path_hash}-{start_timestamp}.log
    ...
```

All files for a given scanned path share the same `{path_hash}` prefix, making it straightforward to identify and clean up related artifacts.

---

## 8. JSON Output Schema

When `--json` is specified, the tool outputs a JSON object conforming to this schema. This is the in-memory representation, not a persisted format. The authoritative schema is defined in [json-output.md](contracts/json-output.md).

```json
{
  "path": "/Users/bioharz",
  "cache_timestamp": "2026-02-13T14:22:01Z",
  "cache_age_seconds": 8040,
  "scan_duration_ms": 45000,
  "entry_count": 15000000,
  "refresh": {
    "status": "running",
    "pid": 48291,
    "estimated_remaining_seconds": 200
  },
  "volume": {
    "total_bytes": 2000398934016,
    "used_bytes": 1847382712320,
    "free_bytes": 153016221696,
    "filesystem": "apfs"
  },
  "entries": [
    {
      "path": "/Users/bioharz/Library",
      "bytes": 524288000000,
      "percent": 28.4,
      "file_count": 4200000,
      "dir_count": 180000,
      "depth": 1
    },
    {
      "path": "/Users/bioharz/Library/Application Support",
      "bytes": 312000000000,
      "percent": 16.9,
      "file_count": 2800000,
      "dir_count": 95000,
      "depth": 2
    }
  ]
}
```

The `refresh` field is present only when a background session exists for the queried path (set to `null` otherwise). The `entries` array is truncated to `--top N` entries and filtered to `--depth N` depth.

This example mirrors the authoritative schema in [json-output.md](contracts/json-output.md). The output layer converts stored relative paths to absolute paths for JSON serialization.
