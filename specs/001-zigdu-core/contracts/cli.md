# Contract: CLI Interface

**Scope**: Defines the complete command-line interface for `zigdu` - arguments, flags, options, exit codes, and output streams.

## Command Syntax

```
zigdu [options] [path]
```

## Arguments

| Argument | Position | Required | Default | Description |
|----------|----------|----------|---------|-------------|
| `path` | 1 | No | Current working directory (`.`) | Filesystem path to scan. Resolved to canonical absolute real path (symlinks in parent components resolved, normalized slashes, made absolute). |

## Flags (Boolean)

Flags take no value. Presence enables the behavior.

| Flag | Short | Description |
|------|-------|-------------|
| `--wait` | `-w` | Block until the scan completes instead of returning cached results and spawning a background refresh. Required on first scan if the user wants to see results immediately. |
| `--force` | `-f` | Discard any existing cache for the path and perform a fresh scan. Implies `--wait`. |
| `--json` | `-j` | Output structured JSON to stdout instead of human-readable format. See [json-output.md](json-output.md) for the schema. |
| `--verbose` | `-v` | Emit diagnostic output to stderr: skipped paths, cache hit/miss, APFS detection, timing, background process details. |
| `--cross-mount` | | Cross filesystem boundaries during scanning. By default, the tool stays within a single filesystem to avoid scanning network volumes or external drives unexpectedly. |

## Options with Values

| Option | Short | Type | Default | Description |
|--------|-------|------|---------|-------------|
| `--depth N` | `-d N` | Integer >= 1 | `3` | Maximum directory depth to display in the output. The scan always traverses the full tree; this controls only how deep the output is rendered. |
| `--top N` | `-t N` | Integer >= 1 | `20` | Maximum number of entries to display at each depth level, sorted by size descending. Entries beyond this limit are aggregated into an "other" summary. |
| `--kill PID` | | Integer | | Send a graceful shutdown signal to the background scan process with the given PID. The process cleans up its socket, PID file, and cache temp files before exiting. |

## Standalone Commands

These flags cause the tool to perform a single action and exit. They are mutually exclusive with each other and with scan operations.

| Command | Description |
|---------|-------------|
| `--sessions` | List all active background scan sessions. Each entry shows: target path, PID, start time, files scanned so far, and estimated remaining time. Output goes to stdout. |
| `--status` | Query the progress of a running background scan for the resolved path argument (or current directory). Connects to the session's Unix domain socket and retrieves progress. |
| `--help` | Print usage information and exit. |
| `--version` | Print version string (format: `zigdu X.Y.Z`) and exit. |

## Exit Codes

| Code | Meaning | When |
|------|---------|------|
| `0` | Success | Scan completed (or cached results returned) without errors. |
| `1` | Error | Fatal error: path does not exist, permission denied on the root path, cache directory unwritable, invalid arguments, or IPC failure. |
| `2` | Partial results with warnings | Scan completed but some subdirectories were inaccessible or errors occurred during traversal. Results are displayed for the accessible portion. Warnings are emitted to stderr. |

## Output Streams

### stdout

- **Human-readable mode (default)**: Tabular output with columns for size (human-readable), percentage, visual bar, and path. Includes a header with cache metadata (timestamp, age) and a footer with volume summary (total, used, free). Progress information for background refresh is appended after the table.
- **JSON mode (`--json`)**: A single JSON object per invocation. See [json-output.md](json-output.md) for the schema. No other text is mixed into stdout when `--json` is active.

### stderr

- Warnings about inaccessible directories (always emitted).
- Verbose diagnostics when `--verbose` is active.
- Progress indicators during `--wait` scans (e.g., files scanned, elapsed time).
- Error messages for fatal failures.

## Argument Validation

- If `path` does not exist, exit with code `1` and print an error to stderr.
- If `--depth` or `--top` receives a non-positive integer or non-integer value, exit with code `1` and print a usage hint to stderr.
- If `--kill` receives a PID that does not correspond to a known zigdu session, exit with code `1` and print an error to stderr.
- If mutually exclusive standalone commands are combined, exit with code `1` and print a usage hint to stderr.

## Precedence and Combination Rules

- `--force` implies `--wait`. When both are specified, the cache is discarded and the tool blocks until the fresh scan completes.
- `--json` can be combined with any scan operation or standalone command. When combined with `--sessions`, the session list is output as JSON. When combined with `--status`, the status response is output as JSON.
- `--verbose` output always goes to stderr, so it is safe to combine with `--json` (stdout remains clean JSON).
- `--depth` and `--top` apply only to scan output (not to `--sessions` or `--status`).
