# zigdu

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Fast, cache-first disk usage scanning for humans, scripts, and autonomous agents.

`zigdu` scans directory trees, stores structured cache results, and returns warm responses quickly on repeated runs. It also supports background refresh sessions with explicit status and cancellation controls.

## Why zigdu

- Fast repeat checks with warm local cache
- Script-friendly JSON output (`--json`)
- Background refresh flow for non-blocking automation
- Session controls for orchestration (`--sessions`, `--status`, `--kill`)
- Clear exit codes for reliable CI/agent handling

## Quick start

### Requirements

- [Zig](https://ziglang.org) to build
- macOS or Linux (Unix sockets required)

### Build and run

```bash
git clone <your-fork-or-origin-url>
cd zigdu
zig build
./zig-out/bin/zigdu --help
```

You can also run via Zig directly:

```bash
zig build run -- [options] [path]
```

## First 30 seconds

```bash
# 1) Scan once and block until completion
./zig-out/bin/zigdu /Users/you --wait

# 2) Read from cache (usually much faster)
./zig-out/bin/zigdu /Users/you

# 3) JSON for automation
./zig-out/bin/zigdu /Users/you --json
```

## Common commands

```bash
# Fresh full scan
zigdu /some/path --force --wait

# Limit output rendering (scan still traverses full tree)
zigdu /some/path --depth 3 --top 20

# Session controls
zigdu --sessions
zigdu /some/path --status
zigdu --kill 12345
```

## Exit codes

- `0`: success
- `1`: fatal error (invalid args, root path failure, IPC/runtime error)
- `2`: partial results with warnings (for example, inaccessible subdirectories)

This makes it safe to distinguish hard failure from usable-but-partial output in scripts.

## JSON output at a glance

`--json` returns a single JSON object with fields such as:

- `path`
- `cache_timestamp`
- `cache_age_seconds`
- `scan_duration_ms`
- `entry_count`
- `refresh`
- `volume`
- `entries`

Session/status commands also emit structured JSON when combined with `--json`.

## Configuration

Config file:

```text
~/.zigdu/config
```

Format: `key = value`, one per line, `#` comments supported.

Supported keys:

- `base_dir`
- `cache_dir`
- `log_dir`
- `max_cache_bytes`
- `default_depth`
- `default_top`
- `max_log_age_days`

Defaults:

```text
base_dir=~/.zigdu
cache_dir=~/.zigdu/cache
log_dir=~/.zigdu/logs
max_cache_bytes=1073741824
default_depth=3
default_top=20
max_log_age_days=30
```

## Cache and runtime files

- Cache payload: `<cache_dir>/<path_hash>.zgdu`
- APFS/HFS+ metadata: `<cache_dir>/<path_hash>.gencount`
- Session PID: `<cache_dir>/<path_hash>.pid`
- Session socket: `<cache_dir>/<path_hash>.sock`
- Daemon logs: `<log_dir>/<path_hash>-YYYYMMDD-hhmmss.log`

`path_hash` is a 16-character hex hash of the canonicalized path.

## Project goals

- Keep repeated storage introspection fast and predictable
- Provide machine-stable outputs for agentic workflows
- Preserve useful partial results instead of failing hard on every inaccessible subtree

## CLI reference

Primary flags and options:

- `--help`, `-h`
- `--version`
- `--wait`, `-w`
- `--force`, `-f`
- `--json`, `-j`
- `--verbose`, `-v`
- `--cross-mount`
- `--depth`, `-d <N>`
- `--top`, `-t <N>`
- `--sessions`
- `--status`
- `--kill <PID>`

`--sessions`, `--status`, and `--kill` are mutually exclusive.
