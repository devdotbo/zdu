# Implementation Plan: zdu - Fast Disk Usage Scanner with Persistent Cache

**Branch**: `001-zdu-core` | **Date**: 2026-02-13 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-zdu-core/spec.md`

## Summary

A Zig-native CLI tool that scans directory trees for disk usage, persists results in a binary cache for instant retrieval on subsequent runs, and spawns background daemon processes to keep caches fresh. On macOS/APFS, the tool uses `ATTR_CMNEXT_RECURSIVE_GENCOUNT` via `getattrlist()` to validate cached subtrees in microseconds and `getattrlistbulk()` for batched directory traversal. Cross-platform (macOS + Linux) with a single CLI interface, JSON output for machine consumption, and IPC via Unix domain sockets for session management.

## Technical Context

**Language/Version**: Zig 0.15.2 (latest stable, released 2025-10-12)
**Primary Dependencies**: Zig standard library only (no external packages); macOS libc headers via `extern "c"` declarations for `getattrlistbulk`, `getattrlist`, `setpriority`
**Storage**: Binary cache files under `~/.zdu/cache/`, logs under `~/.zdu/logs/`, config at `~/.zdu/config`
**Testing**: Zig built-in test framework (`zig build test`)
**Target Platform**: macOS (APFS, HFS+) and Linux (ext4, XFS, btrfs)
**Project Type**: single
**Performance Goals**: <50ms cached retrieval, <60s cold scan of 1.8TB/15M files, cache validation <1s on APFS
**Constraints**: <200MB memory during scan, <500MB cache for 15M entries, no external runtime dependencies, no GC
**Scale/Scope**: Volumes up to 1.8TB with 15M+ inodes, concurrent background scan sessions, LRU cache eviction at 1GB cap

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Status: PASS (no active constitution)**

The project constitution (`/.specify/memory/constitution.md`) contains only template placeholders - no principles have been ratified. There are no active gates to evaluate. The plan proceeds without constitutional constraints.

When a constitution is established, this section should be re-evaluated.

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
build.zig                    # Build configuration (cross-platform, libc linking)
build.zig.zon                # Package manifest
src/
├── main.zig                 # CLI entry point (arg parsing, dispatch)
├── scanner.zig              # Core directory tree scanning logic
├── cache.zig                # Cache read/write/eviction (binary format, mmap, LRU)
├── daemon.zig               # Background process spawn/management
├── ipc.zig                  # Unix domain socket IPC (status, cancel, result)
├── output.zig               # Human-readable and JSON output formatting
├── types.zig                # Shared data types (ScanResult, CacheEntry, etc.)
├── path.zig                 # Path canonicalization and hashing
└── platform/
    ├── darwin.zig            # macOS: getattrlistbulk, getattrlist (RECURSIVE_GENCOUNT), PRIO_DARWIN_BG
    ├── linux.zig             # Linux: ioprio_set (IOPRIO_CLASS_IDLE)
    └── generic.zig           # Platform abstraction interface and fallback
```

**Structure Decision**: Single project with platform-specific code isolated in `src/platform/`. Zig's
`builtin.os.tag` enables conditional compilation at build time. No separate test directory -- tests live
alongside source as Zig `test` blocks, following community convention for discoverability. The build
produces a single `zdu` binary that acts as both CLI and (when spawned as background) daemon.

## Phase 0: Research (Complete)

All technical unknowns from the spec have been researched and resolved. See [research.md](research.md) for full details.

Key decisions:
1. **Zig 0.15.2** confirmed as latest stable (2025-10-12), with I/O API changes (non-generic Reader/Writer)
2. **Directory traversal**: `std.fs.Dir.Iterator` on Linux (wraps `getdents64`), `getattrlistbulk()` via `extern "c"` on macOS
3. **APFS cache validation**: `getattrlist()` with `ATTR_CMNEXT_RECURSIVE_GENCOUNT` for per-subtree change detection
4. **Background throttling**: `PRIO_DARWIN_BG` (single call) on macOS, `nice(19)` + `ioprio_set(IOPRIO_CLASS_IDLE)` on Linux
5. **IPC**: Unix domain sockets with text commands and JSON responses
6. **Daemonization**: `std.posix.fork()` + `std.c.setsid()` with PID file tracking
7. **Cache format**: 32-byte extern struct header + variable-length entries, little-endian, mmap for reads
8. **LRU eviction**: Filesystem mtime-based, no index file, opportunistic during cache writes
9. **Thread pool**: `std.Thread.Pool` with `spawnWg` + `waitAndWork` for parallel traversal
10. **Atomic writes**: `std.fs.Dir.atomicFile` (write to temp, rename on finish)

## Phase 1: Design & Contracts (Complete)

### Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Data Model | [data-model.md](data-model.md) | Entity definitions, binary format spec, state transitions, validation rules |
| CLI Contract | [contracts/cli.md](contracts/cli.md) | Command syntax, flags, options, exit codes, output streams |
| IPC Protocol | [contracts/ipc-protocol.md](contracts/ipc-protocol.md) | Socket transport, text commands, JSON responses, session tracking |
| JSON Schema | [contracts/json-output.md](contracts/json-output.md) | Scan result, status, cancel, sessions, error JSON schemas |
| Quickstart | [quickstart.md](quickstart.md) | Build, run, test instructions and project layout |

### Key Design Decisions

- **Binary cache format**: 32-byte header (magic "ZDU0", version, timestamp, duration, entry_count) followed by variable-length entries in depth-first pre-order. Tree reconstructed on read from depth values.
- **Volume info**: Retrieved fresh via `statfs()`/`statvfs()` on each invocation, not persisted in cache (free/used space changes too frequently).
- **APFS gencounts**: Stored in companion `.gencount` files alongside `.zdu` cache files, keeping the core binary format platform-independent.
- **Config format**: Simple key=value text file at `~/.zdu/config`. CLI flags override config values, which override compiled defaults.
- **Session state machine**: idle -> scanning -> completing -> done -> cleaned, with error state reachable from scanning/completing.

## Constitution Check (Post-Design)

**Status: PASS (no active constitution)**

Re-evaluated after Phase 1 design completion. The constitution (`/.specify/memory/constitution.md`) remains template-only with no ratified principles. No design decisions conflict with any constitutional constraints because none exist.

## Complexity Tracking

> No constitution violations to track. No active constitution exists.
