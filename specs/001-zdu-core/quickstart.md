# zdu Quickstart

Fast disk usage scanning with persistent cache. Zig 0.15.2 CLI targeting macOS (APFS) and Linux (ext4/XFS/btrfs).

## Prerequisites

- Zig 0.15.2 (install via `brew install zig` on macOS or download from ziglang.org)
- macOS 12+ or Linux (kernel 5.x+)
- No external dependencies (Zig std only + macOS libc headers)

## Build

```bash
zig build                    # debug build
zig build -Doptimize=.ReleaseFast  # optimized build
```

Output binary: `zig-out/bin/zdu`

## Run

```bash
# First scan (no cache)
./zig-out/bin/zdu /path --wait

# Subsequent runs (cached, instant)
./zig-out/bin/zdu /path

# JSON output for tooling
./zig-out/bin/zdu /path --json

# Control output
./zig-out/bin/zdu /path --depth 2 --top 10
```

## Test

```bash
zig build test               # run all tests
zig build test -Dtest-filter="cache"  # filter tests
```

## Project Layout

```
build.zig
build.zig.zon
src/
  main.zig          # CLI entry point
  scanner.zig       # Core scanning logic
  cache.zig         # Cache read/write/eviction
  daemon.zig        # Background process management
  ipc.zig           # Unix domain socket IPC
  output.zig        # Human and JSON output formatting
  platform/
    darwin.zig       # macOS: getattrlistbulk, getattrlist, PRIO_DARWIN_BG
    linux.zig        # Linux: ioprio_set
    generic.zig      # Fallback for other platforms
  types.zig         # Shared data types
```

## Data Directory

```
~/.zdu/
  cache/            # Binary cache files (<hash>.zdu)
  logs/             # Background scan logs
  config            # Optional config file (cache size cap, defaults)
```

## Key Development Notes

- On macOS, link libc for getattrlistbulk/getattrlist: `exe.root_module.link_libc = true;`
- Conditional compilation: `const is_darwin = builtin.os.tag == .macos;`
- Cache files use little-endian byte order
- Atomic writes via `std.fs.Dir.atomicFile` for crash safety
