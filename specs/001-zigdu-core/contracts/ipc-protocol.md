# Contract: IPC Protocol

**Scope**: Defines the inter-process communication protocol between the foreground `zigdu` CLI and background scan daemon processes.

## Transport

- **Mechanism**: Unix domain socket (stream type, `AF_UNIX` / `SOCK_STREAM`).
- **Socket path**: `~/.zigdu/cache/<path-hash>.sock`
  - `<path-hash>` is a deterministic hash of the canonical absolute real path being scanned, used to uniquely identify sessions per path.
  - The hash function is the same one used for cache file naming.
- **Lifecycle**: The background process creates the socket on startup and removes it on exit (normal or error). The foreground process connects as a client.
- **Permissions**: Socket is created with mode `0600` (owner read/write only).

## Protocol Format

- **Request**: Newline-delimited plain text commands. Each command is a single ASCII string terminated by `\n`. No headers, no framing beyond the newline.
- **Response**: A single JSON object per command, terminated by `\n`. The JSON is always a single line (no pretty-printing over the wire).
- **Connection model**: Short-lived. The client connects, sends one command, reads one response, and disconnects. No persistent sessions or multiplexing.

## Commands

### `status`

Query the current progress of the background scan.

**Request**:
```
status\n
```

**Response**:
```json
{
  "status": "running",
  "files_scanned": 4821903,
  "bytes_scanned": 892341902345,
  "estimated_remaining_seconds": 42,
  "percent_complete": 68.4
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | `string` | One of: `"running"`, `"finalizing"`, `"complete"`, `"error"`. `"finalizing"` means the scan is done traversing and is writing the cache. |
| `files_scanned` | `integer` | Number of files and directories enumerated so far. |
| `bytes_scanned` | `integer` | Cumulative size in bytes of all files scanned so far. |
| `estimated_remaining_seconds` | `integer \| null` | Estimated seconds until completion. `null` if the estimate is not yet available (early in the scan). |
| `percent_complete` | `number \| null` | Percentage of the scan completed (0.0-100.0). `null` if not yet estimable. Based on the ratio of `bytes_scanned` to the known volume used space. |

### `cancel`

Request graceful cancellation of the background scan. The process will stop scanning, clean up resources (remove socket and PID file, flush any partial log), and exit.

**Request**:
```
cancel\n
```

**Response**:
```json
{
  "status": "cancelled"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | `string` | Always `"cancelled"` on success. If the scan was already complete, the response will be `{"status": "already_complete"}`. |

The background process exits after sending this response. The client should expect the connection to close shortly after receiving the response.

### `result`

Retrieve the full scan result. If the scan is still running, this blocks until the scan completes (or returns an error if the scan fails).

**Request**:
```
result\n
```

**Response**: The full JSON scan result object, identical in schema to the `--json` CLI output. See [json-output.md](json-output.md) for the complete schema.

If the scan is still in progress, the background process will hold the connection open and send the response only when the scan completes. The client should be prepared for a potentially long wait.

If the scan encountered a fatal error, the response is:
```json
{
  "error": "description of the failure",
  "partial_result": null
}
```

## Error Handling

- **Socket does not exist**: The foreground process should report that no background scan is running for the given path and exit with code `1`.
- **Connection refused**: The socket file exists but no process is listening (stale socket). The foreground process should remove the stale socket file and PID file, then report no active scan.
- **Malformed command**: The background process responds with:
  ```json
  {"error": "unknown command", "command": "<received-text>"}
  ```
  and closes the connection.
- **Background process crash**: If the background process dies without cleanup, stale socket and PID files may remain. The foreground process validates liveness by checking whether the PID in the PID file is still running before attempting a socket connection.

## Session Tracking Files

Each background scan session produces the following files:

### PID File

- **Path**: `~/.zigdu/cache/<path-hash>.pid`
- **Contents**: The process ID as a decimal ASCII string, followed by a newline. No other content.
- **Example**: `48291\n`
- **Lifecycle**: Created atomically (write to temp file, then rename) before the socket is opened. Removed on process exit.
- **Purpose**: Enables duplicate detection (FR-007) and liveness checking. Before spawning a new background process, the foreground checks for an existing PID file and verifies the PID is still alive via `kill(pid, 0)`.

### Socket File

- **Path**: `~/.zigdu/cache/<path-hash>.sock`
- **Lifecycle**: Created by the background process on startup via `bind()`. Removed (unlinked) on process exit.
- **Purpose**: IPC channel for status queries, cancellation, and result retrieval.

### Log File

- **Path**: `~/.zigdu/logs/<path-hash>-<timestamp>.log`
  - `<timestamp>` format: `YYYYMMDD-HHMMSS` in UTC (e.g., `20260213-142201`).
- **Contents**: Line-oriented plain text log. Each line is prefixed with an ISO 8601 timestamp and a level tag:
  ```
  2026-02-13T14:22:01Z [INFO] scan started for /Users/bioharz
  2026-02-13T14:22:01Z [DEBUG] APFS volume detected, using getattrlistbulk
  2026-02-13T14:35:12Z [WARN] permission denied: /Users/bioharz/.Trash
  2026-02-13T14:44:58Z [INFO] scan complete: 14832901 files, 1.8TB, 45.2s
  ```
- **Lifecycle**: Created when the background process starts. Never deleted by the process itself. Subject to log rotation or manual cleanup by the user.
- **Purpose**: Post-hoc diagnosis of background scan behavior (FR-025). One log file per session to avoid interleaving output from concurrent scans.

## Stale Resource Cleanup

The foreground process performs opportunistic cleanup of stale resources:

1. When connecting to a session, first read the PID file and check liveness.
2. If the PID is not alive, remove both the `.pid` and `.sock` files.
3. During `--sessions`, enumerate all `.pid` files in `~/.zigdu/cache/`, check liveness for each, and clean up stale entries.
