# zigdu - Fast Disk Usage Scanner with Persistent Cache

## Problem

Disk usage scans on large volumes (1.8 TB, millions of inodes) take minutes.
CLI agents and humans need quick answers about storage, not minutes of waiting.

## Core Idea

A Zig-native disk usage tool that:
- Returns cached results instantly on first invocation
- Spawns a background refresh process automatically
- Provides cache metadata (timestamp, staleness, estimated refresh completion)
- Exposes a session-like interface to communicate with the background process

## Architecture

### Components

1. **zigdu CLI** - the main entry point
2. **zigdu daemon** - the background scanner process
3. **Cache store** - on-disk cache of scan results (e.g. `~/.cache/zigdu/`)
4. **IPC socket** - Unix domain socket for CLI-to-daemon communication

### Flow

```
User runs: zigdu /

  1. CLI checks cache at ~/.cache/zigdu/<path-hash>.cache
  2. If cache exists:
     - Print cached results immediately
     - Print cache timestamp and staleness (e.g. "cached 2h 14m ago")
     - Spawn background daemon (if not already running) to refresh
     - Print daemon PID and estimated refresh time
  3. If no cache exists:
     - Spawn daemon to scan
     - Print "scanning in background, PID <pid>"
     - Optionally: --wait flag to block until first scan completes
```

### CLI Interface

```
zigdu <path>              Show cached results, trigger background refresh
zigdu <path> --wait       Block until scan completes (first run or forced refresh)
zigdu <path> --force      Discard cache, force full rescan
zigdu <path> --status     Query running daemon: progress, ETA, PID
zigdu <path> --top N      Show top N largest directories (default: 20)
zigdu <path> --depth N    Limit directory tree depth (default: 3)
zigdu <path> --json       Output as JSON (for agent consumption)
zigdu --sessions          List all active background scan sessions
zigdu --kill <pid>        Stop a running scan session
```

### Output Format (default)

```
zigdu / - cached results from 2026-02-13 14:22:01 (2h 14m ago)
refresh spawned: PID 48291, estimated completion: ~3m 20s

/Users/bioharz          1.2 TB  ########################################
/Library                 98 GB  ###
/Applications            45 GB  ##
/System                  11 GB  #
/opt                      8 GB  #
/usr                      3 GB
...

Total: 1.6 TB used / 1.8 TB (174 GB free)
```

### Output Format (--json, for agent use)

```json
{
  "path": "/",
  "cache_timestamp": "2026-02-13T14:22:01Z",
  "cache_age_seconds": 8040,
  "refresh": {
    "status": "running",
    "pid": 48291,
    "estimated_remaining_seconds": 200
  },
  "total_bytes": 1977614532608,
  "used_bytes": 1759218604032,
  "free_bytes": 186805252096,
  "entries": [
    {"path": "/Users/bioharz", "bytes": 1319413953536, "percent": 75.0},
    {"path": "/Library", "bytes": 105226698752, "percent": 6.0}
  ]
}
```

## Session / IPC Model

The daemon is **not** tmux - it is a standalone Zig process that:
- Writes a PID file to `~/.cache/zigdu/<path-hash>.pid`
- Listens on a Unix domain socket at `~/.cache/zigdu/<path-hash>.sock`
- Accepts simple text commands over the socket:
  - `status` - returns progress percentage, files scanned, ETA
  - `cancel` - gracefully stops the scan
  - `result` - returns current partial or complete results
- Cleans up PID file and socket on exit

Multiple scans for different paths can run concurrently as separate daemons.

## Cache Format

Binary format for speed, versioned header:

```
[4 bytes] magic: "ZGDU"
[4 bytes] version
[8 bytes] timestamp (unix epoch)
[8 bytes] scan duration (ms)
[8 bytes] total entries count
[repeated] entries:
  [2 bytes] path length
  [N bytes] path (UTF-8)
  [8 bytes] size in bytes
  [4 bytes] file count
  [4 bytes] dir count
  [1 byte]  depth
```

Fallback: `--dump-cache` flag to export cache as JSON for debugging.

## Why Zig

- No runtime overhead, no GC pauses during large directory walks
- Direct syscall access (getdents64 on Linux, getdirentries on macOS) for faster traversal than libc readdir
- Easy cross-compilation for Linux (TrueNAS) and macOS
- Comptime for cache format serialization without reflection overhead
- Thread pool for parallel directory traversal across mount points

## Performance Goals

- Cold scan of 1.8 TB / 15M inodes: under 60 seconds
- Cache load and display: under 50 ms
- Memory usage during scan: under 200 MB
- Cache file size for 15M entries: under 500 MB

## Platform-Specific Optimizations

See [MACOS_NATIVE_APIS.md](MACOS_NATIVE_APIS.md) for detailed investigation of macOS/APFS native APIs.

Key findings:
- `ATTR_CMNEXT_RECURSIVE_GENCOUNT` enables single-syscall cache validation per directory
- `getattrlistbulk()` batches name+type+size reads (fewer syscalls than readdir+stat)
- `searchfs()` may allow catalog-level cold scans (untested)
- No userspace API exists for recursive directory sizes despite APFS dir_stats being enabled

## Future Ideas

- Watch mode using FSEvents (macOS) / inotify (Linux) to keep cache warm incrementally
- Delta scans: only rescan directories with mtime newer than last scan
- TUI mode with interactive drill-down (like ncdu but backed by cache)
- Remote scan mode: `zigdu ssh://bioharz@192.168.0.48/mnt/data`
- Alerts: notify when free space drops below threshold
- Integration: MCP tool server so Claude Code can query storage natively
