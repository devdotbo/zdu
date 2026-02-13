# Feature Specification: zigdu - Fast Disk Usage Scanner with Persistent Cache

**Feature Branch**: `001-zigdu-core`
**Created**: 2026-02-13
**Status**: Draft
**Input**: User description: "Fast disk usage scanner with persistent cache, background daemon refresh, CLI interface with human and machine-readable output, and macOS-native optimizations for APFS volumes"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Scan Disk Usage for a Path (Priority: P1)

A user runs `zigdu <path>` for the first time on a given path. Since no cached results exist, the tool scans the directory tree and displays disk usage broken down by top-level subdirectories, sorted by size descending, with a visual bar chart and total/used/free summary.

**Why this priority**: This is the foundational capability. Without scanning and displaying disk usage, nothing else matters. A user must be able to get an answer to "where is my disk space going?" in a single command.

**Independent Test**: Can be fully tested by running the tool against any directory and verifying that output shows correct sizes, sorted by largest first, with total/used/free summary.

**Acceptance Scenarios**:

1. **Given** a directory path with files and subdirectories, **When** the user runs `zigdu <path> --wait`, **Then** the tool displays each subdirectory with its size, percentage of total, and a proportional bar, sorted largest first.
2. **Given** a directory path, **When** the scan completes, **Then** the output includes total used space, total available space, and free space remaining.
3. **Given** a path that does not exist, **When** the user runs `zigdu <nonexistent>`, **Then** the tool prints a clear error message and exits with a non-zero status code.
4. **Given** a path the user does not have permission to read, **When** the user runs `zigdu <restricted>`, **Then** the tool scans accessible subdirectories, skips inaccessible ones with a warning, and displays results for the accessible portion.

---

### User Story 2 - Instant Cached Results (Priority: P2)

A user runs `zigdu <path>` on a path that has been scanned before. The tool immediately displays the cached results along with the cache age (how long ago the scan was performed), giving the user an instant answer without waiting for a rescan.

**Why this priority**: The primary value proposition of zigdu over existing tools (du, ncdu) is speed through caching. Returning cached results instantly transforms the user experience from "wait minutes" to "answer in milliseconds."

**Independent Test**: Can be tested by running a scan, then running the same command again and verifying that results appear instantly with a cache timestamp and age indicator.

**Acceptance Scenarios**:

1. **Given** a previously scanned path with a valid cache, **When** the user runs `zigdu <path>`, **Then** cached results are displayed within 50 milliseconds with a header showing the cache timestamp and age (e.g., "cached 2h 14m ago").
2. **Given** a cached result, **When** the user runs `zigdu <path> --force`, **Then** the cache is discarded and a fresh scan is performed.
3. **Given** a cached result, **When** the cache file is corrupted or in an incompatible format version, **Then** the tool falls back to a fresh scan and regenerates the cache.

---

### User Story 3 - Background Refresh (Priority: P3)

After displaying cached results, the tool automatically spawns a background process to refresh the cache. The user can continue working while the scan happens. On the next invocation, the user gets fresher results.

**Why this priority**: Background refresh ensures that cached results stay reasonably fresh without the user needing to explicitly trigger rescans. This is the "set and forget" experience that makes zigdu practical for repeated use.

**Independent Test**: Can be tested by running `zigdu <path>` on a cached path, verifying the background process is spawned (PID displayed), waiting for it to complete, then running zigdu again and seeing a more recent cache timestamp.

**Acceptance Scenarios**:

1. **Given** a cached path, **When** the user runs `zigdu <path>`, **Then** a background refresh process is spawned and its PID is displayed to the user.
2. **Given** a background refresh is already running for a path, **When** the user runs `zigdu <path>` again, **Then** the tool detects the existing process and does not spawn a duplicate.
3. **Given** a background refresh is running, **When** the user runs `zigdu <path> --status`, **Then** the tool displays progress information including files scanned and estimated time remaining.
4. **Given** a background refresh is running, **When** the refresh completes, **Then** the cache file is atomically updated so concurrent readers never see partial data.

---

### User Story 4 - Machine-Readable JSON Output (Priority: P4)

An automated tool (e.g., a CLI agent like Claude Code) runs `zigdu <path> --json` and receives structured output containing path sizes, cache metadata, and refresh status, enabling programmatic consumption of disk usage data.

**Why this priority**: JSON output enables integration with other tools and automated workflows. CLI agents need structured data to make decisions about storage management. This extends zigdu's value beyond interactive human use.

**Independent Test**: Can be tested by running `zigdu <path> --json`, parsing the output as JSON, and verifying it contains the expected fields (path, sizes, cache metadata, refresh status).

**Acceptance Scenarios**:

1. **Given** any valid path, **When** the user runs `zigdu <path> --json`, **Then** the output is valid JSON containing: path, cache timestamp, cache age in seconds, total/used/free bytes, and an array of entries with path/bytes/percent.
2. **Given** a background refresh is running, **When** `--json` output is requested, **Then** the JSON includes a `refresh` object with status, PID, and estimated remaining time.
3. **Given** no cache exists, **When** the user runs `zigdu <path> --json --wait`, **Then** the tool blocks until the scan completes and returns the full JSON result.

---

### User Story 5 - Depth and Top-N Controls (Priority: P5)

A user controls the granularity of output by specifying how many levels deep to display (`--depth N`) and how many entries to show (`--top N`), allowing them to focus on the most relevant information for their needs.

**Why this priority**: Default output can be overwhelming on deep directory trees. Depth and top-N controls let users tune the output to their specific question - whether it is "what are the biggest top-level directories?" or "show me 3 levels deep under /Users."

**Independent Test**: Can be tested by running `zigdu <path> --depth 1` and verifying only immediate children are shown, then `--depth 3` and verifying three levels appear, and `--top 5` and verifying only the 5 largest entries are shown.

**Acceptance Scenarios**:

1. **Given** a directory tree, **When** the user runs `zigdu <path> --depth 1`, **Then** only immediate child directories are shown with their sizes.
2. **Given** a directory tree, **When** the user runs `zigdu <path> --depth 3`, **Then** entries up to 3 levels deep are shown in a tree structure.
3. **Given** a directory tree with many entries, **When** the user runs `zigdu <path> --top 5`, **Then** only the 5 largest entries are displayed.
4. **Given** default invocation without flags, **When** the user runs `zigdu <path>`, **Then** the default depth is 3 and the default top count is 20.

---

### User Story 6 - Session Management (Priority: P6)

A user manages active background scan sessions - listing all running scans and stopping ones they no longer need. This prevents resource waste from forgotten background scans.

**Why this priority**: With multiple background scans potentially running for different paths, users need visibility and control. This is a management capability that supports the background refresh feature.

**Independent Test**: Can be tested by starting multiple scans, running `zigdu --sessions` to list them, then `zigdu --kill <pid>` to stop one, and verifying it is no longer listed.

**Acceptance Scenarios**:

1. **Given** one or more background scans are running, **When** the user runs `zigdu --sessions`, **Then** each active session is listed with its target path, PID, start time, and progress.
2. **Given** an active background scan, **When** the user runs `zigdu --kill <pid>`, **Then** the scan is gracefully stopped and its temporary resources are cleaned up.
3. **Given** no background scans are running, **When** the user runs `zigdu --sessions`, **Then** the output indicates no active sessions.

---

### User Story 7 - macOS-Optimized Cache Validation (Priority: P7)

On macOS with APFS volumes, the tool uses native filesystem change detection to determine which cached subtrees are still valid, avoiding full rescans when only a small portion of the filesystem has changed.

**Why this priority**: This is a platform-specific performance optimization. On macOS/APFS, the tool can check whether a cached subtree is still valid in microseconds rather than rescanning millions of files. This makes warm scans near-instant even on multi-terabyte volumes.

**Independent Test**: Can be tested on macOS by scanning a path, modifying a file in one subdirectory, running zigdu again, and verifying that only the changed subtree is rescanned while unchanged subtrees are served from cache.

**Acceptance Scenarios**:

1. **Given** a cached scan on macOS/APFS, **When** no files have changed since the last scan, **Then** the tool validates the cache in under 1 second without rescanning any files.
2. **Given** a cached scan on macOS/APFS, **When** files in one subdirectory have changed, **Then** only that subtree is rescanned while all other subtrees are served from cache.
3. **Given** a non-APFS filesystem or non-macOS platform, **When** the user runs zigdu, **Then** the tool falls back to a full rescan without errors.

---

### Edge Cases

- What happens when the target volume is unmounted or disconnected during a scan? The scan should terminate gracefully, preserve any partial results already cached for other subtrees, and report the error.
- What happens when disk space is completely full? The tool should still be able to display cached results. If no cache exists, it should report the error without crashing.
- What happens when scanning a path that crosses mount points (e.g., `/` includes `/Volumes`)? The tool should not cross filesystem boundaries by default to avoid scanning network volumes or external drives unexpectedly. A `--cross-mount` flag can override this.
- What happens with symbolic links? The tool should not follow symbolic links to avoid double-counting and infinite loops. Symlinks should be reported as their own size (the link itself), not the target's size.
- What happens with extremely deep directory trees (e.g., 1000+ levels)? The tool should handle them without stack overflow, scanning the full depth but only displaying to the user-specified `--depth`.
- What happens when two users scan the same path concurrently? Each user should get their own scan process. Cache writes should be atomic so one process's update does not corrupt another's read.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The tool MUST accept a filesystem path as its primary argument and display disk usage for that path's contents.
- **FR-002**: The tool MUST display each entry with its size in human-readable format (bytes, KB, MB, GB, TB), the percentage of the parent's total, and a proportional visual bar.
- **FR-003**: The tool MUST sort output entries by size in descending order (largest first).
- **FR-004**: The tool MUST persist scan results to a local cache so that subsequent invocations for the same path return instantly.
- **FR-005**: The tool MUST display cache metadata (timestamp, age) when serving cached results.
- **FR-006**: The tool MUST spawn a background process to refresh the cache automatically when cached results are displayed.
- **FR-007**: The tool MUST detect and prevent duplicate background processes for the same path.
- **FR-008**: The tool MUST support `--json` output with structured data including path sizes, cache metadata, and refresh status.
- **FR-009**: The tool MUST support `--depth N` to control the displayed directory depth (default: 3).
- **FR-010**: The tool MUST support `--top N` to limit displayed entries to the N largest (default: 20).
- **FR-011**: The tool MUST support `--wait` to block until a scan completes instead of returning immediately.
- **FR-012**: The tool MUST support `--force` to discard cache and perform a fresh scan.
- **FR-013**: The tool MUST support `--status` to query the progress of a running background scan.
- **FR-014**: The tool MUST support `--sessions` to list all active background scan processes.
- **FR-015**: The tool MUST support `--kill <pid>` to stop a running background scan.
- **FR-016**: The tool MUST NOT follow symbolic links during scanning.
- **FR-017**: The tool MUST NOT cross filesystem boundaries by default (must support `--cross-mount` to override).
- **FR-018**: The tool MUST handle inaccessible directories gracefully by skipping them with a warning and continuing the scan.
- **FR-019**: The tool MUST update cache files atomically so concurrent readers never see partial or corrupt data.
- **FR-020**: On macOS/APFS, the tool MUST use native filesystem change detection to validate cached subtrees, rescanning only changed portions.
- **FR-021**: On non-macOS platforms or non-APFS filesystems, the tool MUST fall back to full rescans without errors.
- **FR-022**: The tool MUST clean up background process resources (process tracking files, communication channels) on exit, whether normal or due to errors.

### Key Entities

- **Scan Result**: A snapshot of disk usage for a path, containing the scanned path, timestamp, scan duration, total/used/free space, and a tree of directory entries each with path, size, file count, and directory count.
- **Cache Entry**: A persisted scan result stored on disk, identified by the scanned path, with a version identifier for format compatibility.
- **Background Session**: A running scan process identified by PID, associated with a target path, with progress state (files scanned, estimated completion) and communication capability for status queries and cancellation.
- **Directory Entry**: A single node in the scan result tree, representing a directory with its cumulative size (all descendants), direct file count, subdirectory count, and depth level.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users receive cached results in under 50 milliseconds for previously scanned paths.
- **SC-002**: A cold scan of 1.8 TB / 15 million files completes in under 60 seconds.
- **SC-003**: The tool uses under 200 MB of memory during scanning of volumes with 15 million files.
- **SC-004**: On macOS/APFS, cache validation for unchanged subtrees completes in under 1 second for volumes with 15 million files.
- **SC-005**: On macOS/APFS, a warm scan where only one subtree has changed rescans only that subtree and completes in under 10 seconds (assuming the changed subtree is less than 5% of the total).
- **SC-006**: The tool runs on both macOS and Linux without platform-specific user-facing differences (same CLI interface and output format).
- **SC-007**: JSON output is valid and parseable by standard JSON parsers, enabling automated consumption by CLI agents.
- **SC-008**: Background refresh processes do not interfere with the user's foreground workflow - no visible CPU or I/O impact on interactive tasks.

## Assumptions

- Users have standard filesystem permissions; the tool does not require elevated privileges for normal operation.
- The primary storage for cached results is the user's home directory (`~/.cache/zigdu/`), which is assumed to have sufficient space for cache files.
- Cache files for 15 million entries are expected to be under 500 MB.
- The tool targets macOS (APFS) and Linux (ext4, XFS, btrfs) as primary platforms. Other platforms are out of scope for the initial release.
- On macOS, APFS-specific optimizations are used only when the target volume is APFS; other macOS filesystems (HFS+, NFS) use the generic scanning path.
- The `--cross-mount` flag defaults to off, meaning external drives, network volumes, and other mount points are excluded unless explicitly requested.
