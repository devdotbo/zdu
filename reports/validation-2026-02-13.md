# Post-Commit Validation Plan: `.claude` Implementation (T031/T032)

Date: 2026-02-13  
Baseline revision: `HEAD` (post-commit)  
Working directory: `/Users/bioharz/git/zigdu`  
Primary contracts: `specs/001-zigdu-core/contracts/cli.md`, `specs/001-zigdu-core/contracts/json-output.md`

## Validation scope

1. `T031` — Quickstart and functional gates (build, scan, JSON, cache, tests, CLI contracts)
2. `T032` — Performance and platform gates (timing, RSS, APFS behavior, cross-platform checks)

## Preconditions

- No uncommitted changes are required to run the plan.
- Use a clean build directory (optionally `git clean -fdx` if policy allows) or ignore stale artifacts.
- Cached artifacts may exist; note any pre-existing cache/session state as evidence.
- APFS/APFS-only checks in this plan are executed on macOS/APFS only; defer with rationale when not available.

## T031 Functional Quickstart Gates

### P001 baseline
- [ ] Build: `zig build`
  - Expected: exit code `0`, artifact at `zig-out/bin/zigdu`
  - Evidence: command output + `ls zig-out/bin/zigdu`

### P002 human and JSON foreground scans
- [ ] `./zig-out/bin/zigdu /tmp --wait`
  - Verify exit `0` and human output includes scan header + `volume` footer
- [ ] `./zig-out/bin/zigdu /tmp --json --wait`
  - Verify output is valid JSON:
    - `python3 -c 'import sys, json; data=json.load(sys.stdin); print(data["path"]); print(data["refresh"]["status"]);'`
  - Verify required top-level keys exist and are type-correct:
    - `path` string
    - `cache_timestamp` string
    - `cache_age_seconds` number
    - `scan_duration_ms` number
    - `entry_count` number
    - `volume` object
    - `entries` array
    - `refresh` object

### P003 cache warm behavior
- [ ] `./zig-out/bin/zigdu /tmp`
  - Verify exit `0`, cache path indicator is present, and wall time is low (capture `time`)
- [ ] `./zig-out/bin/zigdu /tmp --json`
  - Verify strict JSON output with `python3 -m json.tool` (or `jq`)

### P004 test/build quality
- [ ] `zig build test`
- [ ] Verify all inline tests pass (no regressions)

### P005 CLI contract checks
- [ ] `./zig-out/bin/zigdu --help`
  - Validate all flags from `cli.md` are present and no scan attempt occurs
- [ ] `./zig-out/bin/zigdu --version`
  - Verify format `zigdu <semver>`
- [ ] `./zig-out/bin/zigdu /tmp --sessions`
  - Human and `--json` forms both valid and non-crashing when no active sessions
- [ ] `./zig-out/bin/zigdu /tmp --status`
- [ ] `./zig-out/bin/zigdu --kill <pid>` (only when session exists)
  - Validate success/error behavior is contract-aligned and JSON path emits `formatErrorJson` on failures

## T032 Performance + Platform Gates

### P006 cold vs cached latency
- [ ] **SC-001**: cache retrieval latency (<50ms target)
  - Warm cache with: `./zig-out/bin/zigdu /tmp --force --wait`
  - Run at least 5 warm runs: `./usr/bin/time -p ./zig-out/bin/zigdu /tmp`
  - Record min/median/p99 and median `< 0.05s` in final log
- [ ] **SC-002**: cold scan baseline
  - Run stable large directory scan with `--force --wait`
  - Record elapsed runtime; target `< 60s` (or environment exception)

### P007 memory and resource checks
- [ ] **SC-003**: RSS
  - macOS: `/usr/bin/time -l ./zig-out/bin/zigdu <path> --wait`
  - Linux: `/usr/bin/time -v ./zig-out/bin/zigdu <path> --wait`
  - Capture peak RSS; target `< 200MB`

### P008 APFS optimization checks (macOS/APFS only)
- [ ] **SC-004**: unchanged cache validation
  - Warm scan and rerun; unchanged-validation wall time `< 1s` for common paths
- [ ] **SC-005**: partial subtree refresh
  - mutate one subtree under cached path, run warm invocation
  - confirm behavior uses partial refresh path and is faster than full scan

### P009 portability checks
- [ ] **SC-006**: cross-compilation
  - `zig build -Dtarget=x86_64-linux`
  - Confirm success or capture deterministic environment blocker
- [ ] CLI parity check on each target
  - Compare `--help` and `--version` semantics vs `cli.md` on Linux target path
  - Verify `--depth`, `--top`, `--json`, and session flags accept and format consistently

## Evidence capture

- Create command transcript in this file under `## Execution Log` with timestamped entries.
- Collect:
  - command
  - exit code
  - stdout/stderr snippets
  - timing (`real/user/sys`)
  - environment details (OS, host, target path, filesystem)
- For any gate failure:
  - mark `[FAIL]` with exact repro steps
  - add “root cause” hypothesis and immediate next step
- APFS unavailable:
  - log as `SKIP (environment)` and proceed to remaining checks.

## Completion criteria

- **T031**: complete only when all P001–P005 pass (or justified skips recorded).
- **T032**: complete only when all P006–P009 pass with explicit thresholds met, or environment-limited skips are documented.
- Final status must be written here as:
  - `T031: PASS / BLOCKED / PARTIAL`
  - `T032: PASS / BLOCKED / PARTIAL`

## Execution Log

- (to be filled during execution)
