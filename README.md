# zigdu

`zigdu` is a small Zig-native CLI that scans directory trees and keeps results warm in a local cache.  
It can return fast cached output, then refresh in the background without blocking the foreground command.

## Requirements

- [Zig compiler](https://ziglang.org) (to build)
- Unix-like system with Unix sockets (Linux/macOS supported by the codebase)

## Build

```bash
cd /path/to/your/zigdu/repo
zig build
```

Run the binary:

```bash
./zig-out/bin/zigdu
```

Or run directly:

```bash
zig build run -- [options] [path]
```

## Basic usage

```bash
zigdu /            # scan root path (uses cache when available)
zigdu / --wait     # block until scan completes
zigdu / --force    # force a fresh full scan
zigdu / --json     # emit machine-readable JSON
zigdu / --depth 2 --top 10
zigdu --sessions   # list active background sessions
zigdu --status --path /tmp
zigdu --kill 12345 # stop session for pid
```

Notes:

- Default path is `.`.
- `--wait` and `--force` are useful when you need fresh, deterministic output.
- `--cross-mount` lets scan traverse filesystem boundaries.
- Exit code `2` indicates scan completed with warnings; `1` indicates argument/runtime error.

## Command line options

- `--help`, `-h`
- `--version`
- `--wait`, `-w`
- `--force`, `-f`
- `--json`, `-j`
- `--verbose`, `-v`
- `--cross-mount`
- `--depth`, `-d <N>` (default from config)
- `--top`, `-t <N>` (default from config)
- `--sessions`
- `--status`
- `--kill <PID>` or `-k<PID>`
- `--path` is positional and should be the path to scan / query

`--sessions`, `--status`, and `--kill` are mutually exclusive.

## Configuration

Settings are loaded from:

```text
~/.zigdu/config
```

Defaults (from code):

```text
base_dir=~/.zigdu
cache_dir=~/.zigdu/cache
log_dir=~/.zigdu/logs
max_cache_bytes=1073741824
default_depth=3
default_top=20
max_log_age_days=30
```

Config format is `key = value`, one entry per line, `#` comments ignored.

Supported keys:

- `base_dir`
- `cache_dir`
- `log_dir`
- `max_cache_bytes`
- `default_depth`
- `default_top`
- `max_log_age_days`

If `cache_dir` / `log_dir` are omitted, they default to `<base_dir>/cache` and `<base_dir>/logs`.

## Data and cache layout

- Cache result: `<cache_dir>/<path_hash>.zgdu`
- APFS/HFS+ gencount metadata: `<cache_dir>/<path_hash>.gencount`
- Background session pid: `<cache_dir>/<path_hash>.pid`
- Session socket: `<cache_dir>/<path_hash>.sock`
- Daemon logs: `<log_dir>/<path_hash>-YYYYMMDD-hhmmss.log`

`path_hash` is a 16-char hex hash of the canonicalized path.

## Output format

### Human readable

Default output shows:

- cache timestamp and age (or live scan timestamp)
- target path
- max depth/top
- volume summary
- largest directory entries
- optional `refresh` line for active background scans

### JSON

`--json` emits structures compatible with the CLI internals for scripts:

- scan response includes `path`, `cache_timestamp`, `cache_age_seconds`, `scan_duration_ms`, `entry_count`, `refresh`, `volume`, and `entries`.
- session/status JSON includes `pid`, `status`, `elapsed_seconds`, byte/file counters, and optional remaining ETA.

## Designed for agents and AI tools

`zigdu` works well in agentic and AI workflows:

- structured JSON output integrates cleanly with downstream automation
- background sessions (`--sessions`, `--status`, `--kill`) are explicitly scriptable
- cache-first behavior supports fast iterative loops for tools that need repeated storage checks

## Behavior

- Cache hit: returns immediately, optionally starts background refresh when not in `--wait`/`--force`.
- Fresh scan: full scan then writes cache and emits result.
- Background daemon writes progress/status via Unix socket, tracks PID, and cleans session files on exit.
- `--kill` sends a cancel command to matching session socket; completion states and errors are surfaced in CLI output.
