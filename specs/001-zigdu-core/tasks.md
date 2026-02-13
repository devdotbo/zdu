# Tasks: zigdu - Fast Disk Usage Scanner with Persistent Cache

**Input**: Design documents from `/specs/001-zigdu-core/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Each implementation task should include inline Zig `test` blocks alongside the code it produces (Zig community convention). Test assertions are part of the implementation, not separate tasks.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single project**: `src/` at repository root
- Tests live alongside source as Zig `test` blocks (Zig community convention)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, build config, and shared type definitions

- [x] T001 Create project directory structure (`src/`, `src/platform/`) and initialize `build.zig` with Zig 0.15.2 build config (exe target `zigdu` from `src/main.zig`, link libc on macOS via `exe.root_module.link_libc = true` when `builtin.os.tag == .macos`, add `zig build test` step aggregating all source files) and `build.zig.zon` package manifest
- [x] T002 [P] Define all shared data types in `src/types.zig`: `DirectoryEntry` (path, size_bytes, file_count, dir_count, depth, children), `ScanResult` (path, timestamp, duration_ms, volume_info, root_entry, entry_count), `VolumeInfo` (mount_point, fs_type as FsType enum, total/used/free_bytes), `CacheHeader` (extern struct, 32 bytes: magic "ZGDU", version u32, timestamp i64, scan_duration_ms u64, entry_count u64 with comptime size assert), `SessionState` enum, `ScanProgress`, `Config` struct with compiled defaults (base_dir `~/.zigdu`, cache_dir, log_dir, max_cache_bytes 1GB, default_depth 3, default_top 20)
- [x] T003 [P] Implement path canonicalization and hashing in `src/path.zig`: `canonicalize()` resolving symlinks via `std.fs.realpath()`, stripping trailing slashes, ensuring absolute paths (V-010..V-014); `hashPath()` returning 64-bit hash of canonical path as hex string for cache file naming

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Platform abstraction layer for directory traversal and volume info - MUST complete before ANY user story

- [x] T004 Define platform abstraction interface in `src/platform/generic.zig`: `DirIterator` interface wrapping platform-specific directory traversal returning (name, type, size) tuples; `getVolumeInfo(path) VolumeInfo` abstracting statfs/statvfs; `setBackgroundPriority()` abstracting OS throttling; compile-time dispatch via `builtin.os.tag` to select darwin or linux implementation
- [x] T005 [P] Implement macOS platform module in `src/platform/darwin.zig`: extern "c" declarations for `getattrlistbulk()`, `getattrlist()`, `statfs()`; `BulkDirIterator` using `getattrlistbulk()` to batch-read name+type+size per syscall; `getVolumeInfo()` via `statfs()` populating VolumeInfo with fs_type derived from `f_fstypename`; implement the `DirIterator` interface from generic.zig
- [x] T006 [P] Implement Linux platform module in `src/platform/linux.zig`: `DirIterator` wrapping `std.fs.Dir.Iterator` (which uses `getdents64` internally) with `fstatat()` for file sizes; `getVolumeInfo()` via `std.c.statvfs()` populating VolumeInfo with fs_type derived from `f_type` field; implement the interface from generic.zig

**Checkpoint**: Platform layer ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Scan Disk Usage for a Path (Priority: P1) - MVP

**Goal**: A user runs `zigdu <path> --wait` and sees disk usage broken down by subdirectories, sorted by size descending, with bar chart and volume summary.

**Independent Test**: Run `zigdu /some/path --wait` and verify output shows sizes sorted largest first with total/used/free summary. Run against nonexistent path and verify error with exit code 1. Run against path with restricted subdirs and verify partial results with warnings and exit code 2.

### Implementation for User Story 1

- [x] T007 [P] [US1] Implement core directory scanning in `src/scanner.zig`: `scan(path, config) ScanResult` using `std.Thread.Pool` with `spawnWg` for parallel traversal; each top-level subdirectory is a work item; workers use platform `DirIterator` for recursive traversal; accumulate size_bytes, file_count, dir_count per DirectoryEntry; build tree with depth values; skip symlinks (FR-016); respect filesystem boundaries by comparing device IDs unless cross_mount is set (FR-017); skip inaccessible dirs with warning to stderr (FR-018); handle deep trees iteratively with explicit stack (no recursion); accumulate file_count and dir_count recursively (same as size_bytes) -- propagate child counts upward to parent entries; detect I/O errors indicating volume disappearance during traversal, use shared atomic cancellation flag to signal all worker threads to stop gracefully, preserve any partial results; note on memory budget (SC-003): DirectoryEntry nodes represent directories, not files -- for a typical 15M-file volume with ~500K-1M directories at ~60 bytes/entry, peak memory usage should be 30-60MB, well under the 200MB target; if RSS approaches 150MB during scanning, reduce thread pool size or batch-flush intermediate results
- [x] T008 [P] [US1] Implement human-readable output formatting in `src/output.zig`: `formatHumanReadable(ScanResult, depth, top, writer)` rendering table with columns: size (auto-scaled bytes/KB/MB/GB/TB), percentage of parent, proportional ASCII bar (`[========  ]`), and relative path; sort entries by size descending (FR-003); header line with scanned path; footer with volume summary (total, used, free from VolumeInfo); support for cache age display (e.g., "cached 2h 14m ago") when cache_timestamp is provided
- [x] T009 [US1] Implement CLI entry point in `src/main.zig`: parse args using `std.process.ArgIterator` for positional path (default "."), flags --wait/-w, --force/-f, --json/-j, --verbose/-v, --cross-mount, options --depth/-d N, --top/-t N, --kill PID, standalone commands --sessions, --status, --help, --version; validate args per cli.md contract (exit code 1 for invalid); resolve path via `path.canonicalize()`; for this story: implement scan-and-display flow when no cache exists or --wait is specified; note: all flags are parsed here for completeness but handlers for --sessions, --status, and --kill are wired in Phase 8 (T024) -- until then, these code paths are parsed but not routed
- [x] T010 [US1] Wire end-to-end scan flow in `src/main.zig`: when path has no cache (or --wait), call `scanner.scan()`, retrieve `platform.getVolumeInfo()`, call `output.formatHumanReadable()` to stdout, print warnings to stderr for skipped paths, set exit code 0 (success) or 2 (partial results); ensure --help prints usage and --version prints "zigdu 0.1.0"

**Checkpoint**: User Story 1 fully functional - `zigdu <path> --wait` scans and displays disk usage

---

## Phase 4: User Story 2 - Instant Cached Results (Priority: P2)

**Goal**: Running `zigdu <path>` on a previously scanned path returns results instantly from cache with cache age indicator.

**Independent Test**: Scan a path with `--wait`, then run again without `--wait` and verify results appear in <50ms with cache timestamp and age. Run with `--force` and verify fresh scan. Corrupt the cache file magic bytes and verify graceful fallback to rescan.

### Implementation for User Story 2

- [x] T011 [US2] Implement binary cache writer in `src/cache.zig`: `writeCache(scan_result, config) void` using `std.fs.Dir.atomicFile()` for crash-safe writes; write 32-byte CacheHeader (magic "ZGDU", version 1, timestamp, duration, entry_count) then all DirectoryEntry records in depth-first pre-order (2B path_len + path bytes + 8B size_bytes + 4B file_count + 4B dir_count + 1B depth) using `writer.writeInt(T, val, .little)` for integers; seek back to patch entry_count in header; file path is `{cache_dir}/{path_hash}.zgdu`; update mtime after write for LRU tracking; handle atomicFile failure (disk full, permission denied) gracefully -- log warning to stderr, do not crash; atomicFile cleans up temp file on failure
- [x] T012 [US2] Implement binary cache reader in `src/cache.zig`: `readCache(path_hash, config) ?ScanResult` using `posix.mmap` with `PROT.READ`, `.TYPE = .PRIVATE`, `MADV.SEQUENTIAL` for zero-copy reads; validate header: magic == "ZGDU" (V-001), version == 1 (V-002), timestamp > 0 and <= now (V-003), entry_count > 0 (V-004), file size consistency (V-005); parse variable-length entries reading `path_len` then path bytes then fixed fields using `std.mem.readInt`; reconstruct tree from flat entries using depth-stack algorithm (V-007, V-008); update file mtime via `updateTimes()` on successful read; return null on any validation failure (triggers rescan)
- [x] T013 [US2] Implement LRU cache eviction in `src/cache.zig`: `evictIfNeeded(config) void` scanning `{cache_dir}/*.zgdu` files, collecting (path, size, mtime) tuples, sorting by mtime ascending; if total size exceeds `config.max_cache_bytes`, delete oldest files until under cap; run opportunistically during cache writes (FR-023); also delete corresponding `.gencount`, `.pid`, `.sock` companion files when evicting
- [x] T014 [US2] Integrate cache into `src/main.zig` scan flow: on invocation, compute path_hash, attempt `readCache()`; if cache hit and no --force: display cached results with cache age header (timestamp + "cached Xh Ym ago"), then proceed to background refresh (US3, for now just return); if cache miss or --force: run scanner, write cache, display results; handle corrupt cache gracefully by falling back to fresh scan; if cache write fails (disk full), continue to display results to the user -- cache persistence is best-effort, not blocking

**Checkpoint**: Cached results return in <50ms; `--force` triggers rescan; corrupt cache triggers automatic rescan

---

## Phase 5: User Story 3 - Background Refresh (Priority: P3)

**Goal**: After displaying cached results, a background process refreshes the cache silently. The user sees fresher results on the next run.

**Independent Test**: Run `zigdu <path>` on cached path, verify PID of background process is displayed. Wait for completion. Run `zigdu <path>` again and verify cache timestamp is more recent. Run again and verify no duplicate background process is spawned.

### Implementation for User Story 3

- [x] T015 [P] [US3] Implement background process management in `src/daemon.zig`: `spawnBackground(path, config) u32` using `std.posix.fork()` + `std.c.setsid()` for daemonization; child process: write PID to `{cache_dir}/{path_hash}.pid` atomically, redirect stdout/stderr to log file at `{log_dir}/{path_hash}-{timestamp}.log`, run scanner.scan() + cache.writeCache(), clean up PID file on exit; parent process: return child PID; `isDuplicate(path_hash, config) bool` checking PID file existence and liveness via `kill(pid, 0)` (V-020, V-021); `cleanupStale(path_hash, config)` removing dead PID files and stale sockets (V-022); on volume unmount or fatal I/O error during background scan, transition to error state, log the error, clean up PID file and socket
- [x] T016 [P] [US3] Implement background throttling: in `src/platform/darwin.zig` add `setBackgroundPriority()` calling `extern "c" fn setpriority(c_int, c_uint, c_int) c_int` with `PRIO_DARWIN_PROCESS=4, PRIO_DARWIN_BG=0x1000`; in `src/platform/linux.zig` add `setBackgroundPriority()` calling `std.c.nice(19)` and `ioprio_set` syscall with `IOPRIO_CLASS_IDLE`; call from daemon child process before scanning
- [x] T017 [US3] Integrate background refresh into `src/main.zig`: after displaying cached results (cache hit path), check `daemon.isDuplicate()` - if no existing process, spawn via `daemon.spawnBackground()` and print PID to stderr; if duplicate exists, skip silently (FR-007); daemon child calls `platform.setBackgroundPriority()` before scanning

**Checkpoint**: Background refresh spawns automatically, runs throttled, updates cache for next invocation

---

## Phase 6: User Story 4 - Machine-Readable JSON Output (Priority: P4)

**Goal**: `zigdu <path> --json` outputs valid structured JSON per the json-output.md contract.

**Independent Test**: Run `zigdu <path> --json --wait`, pipe through a JSON parser (e.g., `python3 -m json.tool`), verify valid JSON with fields: path, cache_timestamp, cache_age_seconds, scan_duration_ms, volume, entries array, refresh object.

### Implementation for User Story 4

- [x] T018 [US4] Implement JSON output formatting in `src/output.zig`: `formatJson(ScanResult, ?BackgroundSession, depth, top, writer)` producing JSON per json-output.md schema; top-level fields: path, cache_timestamp (ISO 8601 UTC), cache_age_seconds, scan_duration_ms, refresh (status/pid/estimated_remaining_seconds or null), volume (total_bytes/used_bytes/free_bytes/filesystem), entries array (path/bytes/percent/file_count/dir_count/depth); also implement `formatStatusJson()`, `formatSessionsJson()`, `formatCancelJson()`, `formatErrorJson()` for standalone commands; use `std.json.stringify` or manual JSON writing with proper escaping; serialize FsType to JSON strings per data-model.md mapping (notably hfsplus -> "hfs+")
- [x] T019 [US4] Add --json routing in `src/main.zig`: when --json flag is set, call `output.formatJson()` instead of `formatHumanReadable()` for scan results; route --sessions through `formatSessionsJson()`, --status through `formatStatusJson()`, errors through `formatErrorJson()`; ensure stderr stays clean (no mixing of human text into stdout when --json is active)

**Checkpoint**: `zigdu <path> --json` produces valid, parseable JSON matching the contract schema

---

## Phase 7: User Story 5 - Depth and Top-N Controls (Priority: P5)

**Goal**: Users control output granularity with `--depth N` and `--top N` to focus on the most relevant directories.

**Independent Test**: Run `zigdu <path> --depth 1` and verify only immediate children shown. Run `--depth 3` and verify three levels. Run `--top 5` and verify only 5 largest entries per level. Run without flags and verify defaults (depth 3, top 20).

### Implementation for User Story 5

- [x] T020 [US5] Implement depth filtering and top-N limiting in `src/output.zig`: add `filterEntries(root, max_depth, top_n) []DirectoryEntry` that traverses the tree, prunes entries beyond max_depth, keeps only top_n entries per depth level sorted by size descending, aggregates pruned entries into an "other (N dirs)" summary line with combined size; apply in both `formatHumanReadable()` and `formatJson()` output paths
- [x] T021 [US5] Wire --depth and --top flags in `src/main.zig`: pass parsed --depth N (default from config.default_depth=3) and --top N (default from config.default_top=20) to output formatting functions; validate values are >= 1 (exit code 1 with usage hint per cli.md for invalid values)

**Checkpoint**: Output respects --depth and --top, defaults work, invalid values are rejected

---

## Phase 8: User Story 6 - Session Management (Priority: P6)

**Goal**: Users can list all active background scans and stop ones they no longer need.

**Independent Test**: Start background scans on multiple paths, run `zigdu --sessions` and verify all listed with path/PID/progress. Run `zigdu --kill <pid>` and verify process stops and is no longer listed. Run `--sessions` with no active scans and verify "no active sessions" message.

### Implementation for User Story 6

- [x] T022 [US6] Implement IPC server in `src/ipc.zig`: `startServer(socket_path) std.net.Server` binding Unix domain socket at `{cache_dir}/{path_hash}.sock` with mode 0600; `handleConnection(conn, scan_state)` reading newline-delimited command, dispatching to handler: `status` returns JSON progress (files_scanned, bytes_scanned, percent_complete, estimated_remaining_seconds per ipc-protocol.md), `cancel` sets cancellation flag and returns `{"status":"cancelled"}`, `result` blocks until scan completes and returns full JSON result; close connection after one response; clean up socket file on process exit
- [x] T023 [US6] Implement IPC client in `src/ipc.zig`: `sendCommand(socket_path, command) []const u8` connecting to Unix socket, sending command + newline, reading JSON response; `queryAllSessions(config) []SessionInfo` enumerating `{cache_dir}/*.pid` files, validating liveness (kill(pid,0)), connecting to corresponding `.sock` to get status; stale resource cleanup: if PID dead, remove `.pid` and `.sock` files
- [x] T024 [US6] Integrate IPC into daemon and main: in `src/daemon.zig`, start IPC server alongside scan, pass shared scan progress state to `ipc.handleConnection()`, check cancellation flag during scanner iteration; in `src/main.zig`, implement --sessions (enumerate and display all sessions with path/PID/start_time/progress), --status (query single session for current path), --kill PID (send cancel command to session socket, display confirmation); support both human-readable and --json output for these commands

**Checkpoint**: Users can list, query, and stop background scan sessions

---

## Phase 9: User Story 7 - macOS-Optimized Cache Validation (Priority: P7)

**Goal**: On macOS/APFS, validate cached subtrees via generation counts, rescanning only changed portions.

**Independent Test**: On macOS/APFS: scan a path, modify a file in one subdirectory, run zigdu again, verify only the changed subtree is rescanned (check verbose output). On Linux: verify graceful fallback to full rescan without errors.

### Implementation for User Story 7

- [x] T025 [P] [US7] Implement APFS gencount retrieval in `src/platform/darwin.zig`: `getRecursiveGencount(path) ?u64` using `extern "c" fn getattrlist()` with `ATTR_CMNEXT_RECURSIVE_GENCOUNT` attribute; `getSubtreeGencounts(root_path, depth) []Gencount` collecting gencounts for subtrees up to specified depth; return null for non-APFS volumes (check via VolumeInfo.fs_type)
- [x] T026 [P] [US7] Implement gencount companion file in `src/cache.zig`: `writeGencounts(path_hash, gencounts, config)` writing `{cache_dir}/{path_hash}.gencount` with binary format (magic "GCNT", entry_count, then repeated 2B path_len + path + 8B gencount records per data-model.md section 2.4); `readGencounts(path_hash, config) ?[]Gencount` reading and validating the companion file; delete companion file when evicting cache
- [x] T027 [US7] Implement partial rescan in `src/scanner.zig`: `partialScan(path, stale_subtrees, config) ScanResult` that rescans only the subtrees whose gencounts have changed while preserving cached data for unchanged subtrees; merge rescanned subtrees into existing tree updating size_bytes up to root; called when APFS validation detects partial staleness
- [x] T028 [US7] Integrate APFS cache validation into `src/main.zig` warm path: on cache hit for macOS/APFS volume, read stored gencounts, compare with current gencounts via `platform.getSubtreeGencounts()`; if all match: serve from cache (validation <1s per SC-004); if some differ: call `scanner.partialScan()` for changed subtrees, update cache and gencounts; if non-APFS or non-macOS: fall back to full background rescan (FR-021)

**Checkpoint**: APFS cache validation completes in <1s for unchanged volumes; partial rescans complete in <10s for small changes

---

## Phase 10: Polish & Cross-Cutting Concerns

**Purpose**: Config file support, verbose logging, and final validation

- [x] T029 [P] Implement Config file loading in `src/types.zig`: `Config.load() Config` reading `~/.zigdu/config` key=value format, parsing each known key (cache_dir, log_dir, max_cache_bytes, default_depth, default_top), applying validation rules V-030..V-033 (clamp out-of-range values with warning to stderr), creating `~/.zigdu/`, `cache/`, `logs/` directories if they do not exist; add `max_log_age_days` config key (default: 30, minimum: 1) and on startup delete log files in `{log_dir}/` older than the configured age; called at startup in main.zig before any other operation
- [x] T030 [P] Implement verbose diagnostic logging across modules: in `src/main.zig` pass verbose flag through to scanner and cache; scanner logs to stderr: cache hit/miss, APFS detection, skipped paths, timing; daemon writes structured log lines (`[INFO]`/`[WARN]`/`[DEBUG]` prefixed with ISO 8601 timestamp) to `{log_dir}/{path_hash}-{timestamp}.log` per ipc-protocol.md log format; one log file per background session (FR-025)
- [x] T031 Run quickstart.md validation: build with `zig build`, run `zigdu /tmp --wait`, verify human-readable output; run `zigdu /tmp --json --wait`, verify valid JSON; run `zigdu /tmp` (cached), verify instant return with cache age; run `zig build test`, verify all inline test blocks pass (test blocks are written as part of each implementation task, not as separate tasks).  
  - Completed: build succeeds, scan commands execute, JSON parses, cached behavior confirmed, `zig build test` passes.
- [ ] T032 Run performance and cross-platform validation for success criteria: measure cached result retrieval time and verify <50ms (SC-001); time a cold scan on a large directory and report duration vs 60s target (SC-002); monitor RSS memory during scan and verify <200MB (SC-003); on macOS/APFS, time cache validation for unchanged volume and verify <1s (SC-004); on macOS/APFS, modify one subtree, run warm scan, and verify partial rescan completes in <10s (SC-005); verify `zig build -Dtarget=x86_64-linux` cross-compiles without errors (SC-006); verify `zigdu --help` and `zigdu --version` output format matches cli.md contract on both targets.  
  - Current status: **Partial** in this environment.  
    - SC-001: cached retrieval below 50ms for small target (`/tmp/zigdu-validate`), but `/tmp` dataset warm runs ~130-160ms.
    - SC-002: cold `/usr` scan completed in ~7.7s.
    - SC-003: RSS observed near 4.47MB (`time -l` on cached run).
    - SC-004: APFS branch exercised via verbose logs.
    - SC-005: partial/unchanged-branch execution observed; dedicated timing is pending.
    - SC-006: `zig build -Dtarget=x86_64-linux` fails locally due missing libc headers (`sys/types.h`) in cross target environment.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - start immediately
- **Foundational (Phase 2)**: Depends on Setup (T001 complete for build config, T002 for types)
- **US1 (Phase 3)**: Depends on Foundational (Phase 2) - all platform modules ready
- **US2 (Phase 4)**: Depends on US1 (Phase 3) - needs ScanResult to cache
- **US3 (Phase 5)**: Depends on US2 (Phase 4) - needs cache module for background writes
- **US4 (Phase 6)**: Depends on US1 (Phase 3) - needs ScanResult; can run parallel with US2/US3
- **US5 (Phase 7)**: Depends on US1 (Phase 3) - needs output module; can run parallel with US2/US3/US4
- **US6 (Phase 8)**: Depends on US3 (Phase 5) - needs daemon module for IPC integration
- **US7 (Phase 9)**: Depends on US2 (Phase 4) - needs cache module for gencounts; depends on US1 for scanner
- **Polish (Phase 10)**: Depends on all user stories being complete

### User Story Dependencies

```
Phase 1 (Setup) ──> Phase 2 (Foundational) ──> Phase 3 (US1: Scan)
                                                    │
                                          ┌─────────┼─────────┐
                                          v         v         v
                                    Phase 4     Phase 6    Phase 7
                                    (US2:Cache) (US4:JSON) (US5:Depth)
                                      │   │
                              ┌───────┘   └───────────────┐
                              v                           v
                        Phase 5 (US3: Background)   Phase 9 (US7: APFS)
                              │
                              v
                        Phase 8 (US6: Sessions)
                              │
                              v
                        Phase 10 (Polish) [depends on all phases]
```

### Within Each User Story

- Models/types before services/logic
- Core implementation before integration with main.zig
- [P] marked tasks can run in parallel within their phase

### Parallel Opportunities

**After Phase 2 completes**:
- T007 (scanner.zig) and T008 (output.zig) can run in parallel

**After Phase 3 (US1) completes**:
- US4 (JSON output), US5 (Depth/Top controls) can start in parallel with US2 (Cache)

**After Phase 4 (US2) completes**:
- US3 (Background) and US7 (APFS validation) can start in parallel

**Within Phase 5 (US3)**:
- T015 (daemon.zig) and T016 (platform throttling) can run in parallel

**Within Phase 9 (US7)**:
- T025 (darwin gencount) and T026 (cache gencount) can run in parallel

**Within Phase 10 (Polish)**:
- T029 (config) and T030 (verbose logging) can run in parallel

---

## Parallel Example: User Story 1

```
# After Phase 2 foundational completes, launch in parallel:
Task T007: "Implement core directory scanning in src/scanner.zig"
Task T008: "Implement human-readable output formatting in src/output.zig"

# After T007 + T008 complete:
Task T009: "Implement CLI entry point in src/main.zig"

# After T009 completes:
Task T010: "Wire end-to-end scan flow in src/main.zig"
```

## Parallel Example: After US1 Completes

```
# These three story phases can start in parallel:
Phase 4 (US2): T011 -> T012 -> T013 -> T014 (Cache)
Phase 6 (US4): T018 -> T019 (JSON)
Phase 7 (US5): T020 -> T021 (Depth/Top)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T003)
2. Complete Phase 2: Foundational (T004-T006)
3. Complete Phase 3: User Story 1 (T007-T010)
4. **STOP and VALIDATE**: `zigdu <path> --wait` scans and displays disk usage
5. This is the minimum viable product

### Incremental Delivery

1. Setup + Foundational -> Platform layer ready
2. Add US1 (Scan) -> Test: `zigdu /tmp --wait` shows disk usage (MVP)
3. Add US2 (Cache) -> Test: second run returns instantly with cache age
4. Add US3 (Background) -> Test: background PID displayed, next run shows fresher data
5. Add US4 (JSON) -> Test: `zigdu /tmp --json` produces valid JSON
6. Add US5 (Depth/Top) -> Test: `--depth 1 --top 5` limits output correctly
7. Add US6 (Sessions) -> Test: `--sessions` lists running scans, `--kill` stops them
8. Add US7 (APFS) -> Test: macOS partial rescan works, Linux falls back gracefully
9. Polish -> Config file, verbose logging, quickstart validation

### Suggested MVP Scope

User Story 1 (Phases 1-3, tasks T001-T010) delivers a fully functional disk usage scanner. This is a complete, usable tool before any caching or background features.

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks in the same phase
- [Story] label maps task to specific user story for traceability
- Each user story is independently testable at its checkpoint
- Commit after each task or logical group
- All cache writes use atomicFile for crash safety (FR-019)
- Scanner skips symlinks (FR-016) and respects mount boundaries (FR-017) from US1 onward
- Config file parsing (T029) can be pulled earlier if needed for cache_dir or log_dir customization
