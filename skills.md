# zigdu Skills Guide

## Purpose
Use this file as the operating guide for working on the `zigdu` CLI and its agent-oriented workflows.

## What `zigdu` is
- CLI scanner for directory trees with warm cache behavior.
- Linux/macOS supported (Unix sockets required).
- Focused on machine-readable outputs and automation hooks (`--json`, `--sessions`, `--status`, `--kill`).

## Core commands
- Build: `zig build`
- Run directly: `zig build run -- [options] [path]`
- Execute artifact: `./zig-out/bin/zigdu`
- Tests: `zig build test`
- Cross-compile smoke command: `zig build -Dtarget=x86_64-linux`

## Useful CLI usage
- `zigdu /` scan root
- `zigdu / --wait` block until a scan completes
- `zigdu / --force` force a fresh full scan
- `zigdu / --json` machine output
- `zigdu / --depth 2 --top 10`
- `zigdu --sessions`
- `zigdu --status --path /tmp`
- `zigdu --kill <PID>`

Exit-code contract:
- `0` success without warnings
- `1` argument/runtime error
- `2` warnings while still producing scan output

## Validation workflow (Agent loop)
1. Identify the highest-priority open item.
2. Make the smallest safe fix.
3. Capture evidence in `reports/validation-2026-02-13.md`.
4. Update `Agents.md` (source-of-truth task tracker).

## Known gates and checks
- `T031` functional gates
- `T032` performance/platform gates:
  - warm latency
  - cold scan target
  - RSS target
  - APFS unchanged validation
  - partial refresh evidence
  - cross-compilation check

### Recommended check sequence
- `git status`
- `zig build`
- `zig build test`
- `zig build -Dtarget=x86_64-linux`
- warm/cold timing runs on native host for deterministic evidence
- capture relevant log snippets and test results in the report file

## Data/cache paths
- Defaults are in `~/.zigdu`:
  - cache: `cache_dir` (`~/.zigdu/cache` default)
  - logs: `log_dir` (`~/.zigdu/logs` default)
- Important files (path hash based):
  - cache result `.zgdu`
  - APFS/HFS+ metadata `.gencount`
  - session pid `.pid`
  - daemon socket `.sock`

## Portability notes
- Keep daemon/socket/path-sensitive changes within Unix socket pathname limits.
- Prefer libc-free paths on Linux where possible.
- Maintain APFS attribute probing fallback for unsupported volume errors.
- Treat cross-platform behavior as a first-class requirement.
