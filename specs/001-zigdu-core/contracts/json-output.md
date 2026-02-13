# Contract: JSON Output Schema

**Scope**: Defines the JSON schemas for all structured output produced by `zigdu --json` and IPC responses.

## Scan Result

Returned by `zigdu [path] --json` (foreground) and the `result` IPC command (background).

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

### Field Reference

#### Top-level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | `string` | Yes | The canonical absolute real path that was scanned. |
| `cache_timestamp` | `string` | Yes | ISO 8601 UTC timestamp of when the cached scan result was produced. Format: `YYYY-MM-DDTHH:MM:SSZ`. |
| `cache_age_seconds` | `integer` | Yes | Number of seconds between `cache_timestamp` and the current time. Computed at output time, not stored in the cache. |
| `scan_duration_ms` | `integer` | Yes | How long the scan took to complete, in milliseconds. |
| `entry_count` | `integer` | Yes | Total number of directory entries in the scan tree. |
| `refresh` | `object \| null` | Yes | Information about the background refresh process. `null` if no background refresh is running or relevant. |
| `volume` | `object` | Yes | Volume-level storage information for the filesystem containing `path`. |
| `entries` | `array` | Yes | Flat array of directory entries, sorted by `bytes` descending. Depth and top-N filtering are applied before output. |

#### `refresh` Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `status` | `string` | Yes | One of: `"running"`, `"idle"`, `"none"`. `"running"` means a background refresh is in progress. `"idle"` means a background process exists but is not actively scanning (e.g., completed and waiting for cleanup). `"none"` means no background process exists. |
| `pid` | `integer \| null` | Yes | PID of the background refresh process. `null` when `status` is `"none"`. |
| `estimated_remaining_seconds` | `integer \| null` | Yes | Estimated seconds until the refresh completes. `null` when the estimate is not available or `status` is not `"running"`. |

#### `volume` Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `total_bytes` | `integer` | Yes | Total capacity of the volume in bytes. |
| `used_bytes` | `integer` | Yes | Used space on the volume in bytes. |
| `free_bytes` | `integer` | Yes | Free space on the volume in bytes. |
| `filesystem` | `string` | Yes | Filesystem type identifier. Known values: `"apfs"`, `"ext4"`, `"xfs"`, `"btrfs"`, `"hfs+"`, `"tmpfs"`, `"nfs"`. Unknown filesystems are reported as their raw system identifier string. |

#### `entries` Array Elements

Each element represents a directory in the scanned tree.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | `string` | Yes | Absolute path of the directory. |
| `bytes` | `integer` | Yes | Cumulative size in bytes of all files within this directory and its descendants. |
| `percent` | `number` | Yes | Percentage of the scanned path's total size represented by this entry. Range: 0.0-100.0. Rounded to one decimal place. |
| `file_count` | `integer` | Yes | Total number of regular files within this directory and its descendants. |
| `dir_count` | `integer` | Yes | Total number of subdirectories within this directory and its descendants. |
| `depth` | `integer` | Yes | Depth relative to the scanned path. Immediate children are depth `1`, their children are depth `2`, etc. |

## Status Response

Returned by the `status` IPC command and by `zigdu [path] --status --json`.

```json
{
  "path": "/Users/bioharz",
  "pid": 48291,
  "status": "running",
  "start_time": "2026-02-13T14:22:01Z",
  "elapsed_seconds": 312,
  "files_scanned": 4821903,
  "bytes_scanned": 892341902345,
  "estimated_remaining_seconds": 42,
  "percent_complete": 68.4
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | `string` | Yes | The canonical path being scanned. |
| `pid` | `integer` | Yes | PID of the background scan process. |
| `status` | `string` | Yes | One of: `"running"`, `"finalizing"`, `"complete"`, `"error"`. |
| `start_time` | `string` | Yes | ISO 8601 UTC timestamp of when the background process started. |
| `elapsed_seconds` | `integer` | Yes | Seconds elapsed since the scan started. |
| `files_scanned` | `integer` | Yes | Number of files and directories enumerated so far. |
| `bytes_scanned` | `integer` | Yes | Cumulative bytes scanned so far. |
| `estimated_remaining_seconds` | `integer \| null` | Yes | Estimated seconds to completion. `null` if not yet estimable. |
| `percent_complete` | `number \| null` | Yes | Percentage complete (0.0-100.0). `null` if not yet estimable. |

## Cancel Response

Returned by the `cancel` IPC command and by `zigdu --kill <pid> --json`.

```json
{
  "pid": 48291,
  "path": "/Users/bioharz",
  "status": "cancelled"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `pid` | `integer` | Yes | PID of the cancelled process. |
| `path` | `string` | Yes | The canonical path that was being scanned. |
| `status` | `string` | Yes | One of: `"cancelled"`, `"already_complete"`. |

## Sessions List Response

Returned by `zigdu --sessions --json`.

```json
{
  "sessions": [
    {
      "path": "/Users/bioharz",
      "pid": 48291,
      "start_time": "2026-02-13T14:22:01Z",
      "elapsed_seconds": 312,
      "status": "running",
      "files_scanned": 4821903,
      "bytes_scanned": 892341902345,
      "estimated_remaining_seconds": 42,
      "percent_complete": 68.4
    },
    {
      "path": "/var/log",
      "pid": 48305,
      "start_time": "2026-02-13T14:30:15Z",
      "elapsed_seconds": 18,
      "status": "running",
      "files_scanned": 12400,
      "bytes_scanned": 3400000000,
      "estimated_remaining_seconds": 5,
      "percent_complete": 78.1
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessions` | `array` | Yes | Array of active session objects. Empty array `[]` when no sessions are running. |

Each session element has the same fields as the [Status Response](#status-response).

## Error Response

Returned by any IPC command or CLI operation that encounters a fatal error when `--json` is active.

```json
{
  "error": "path does not exist: /nonexistent",
  "code": 1
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `error` | `string` | Yes | Human-readable error description. |
| `code` | `integer` | Yes | The exit code that would be returned by the CLI. Matches the [exit codes](cli.md#exit-codes) contract. |

## General Conventions

- All timestamps are ISO 8601 in UTC, with `Z` suffix. No timezone offsets.
- All byte values are exact integers (no floating-point approximations).
- Percentages are `number` type, rounded to one decimal place (e.g., `28.4`, not `28.37921`).
- `null` is used for fields where the value is not yet available or not applicable. Fields are never omitted; they are always present with `null` when not applicable.
- The top-level JSON object is always a single line when emitted over IPC. The CLI may pretty-print if stdout is a TTY, but defaults to compact single-line output for piping.
