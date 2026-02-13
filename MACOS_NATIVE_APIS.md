# macOS Native APIs for zdu

Investigation into macOS/APFS native indexing and filesystem APIs that can accelerate disk usage scanning.

## ATTR_CMNEXT_RECURSIVE_GENCOUNT - Cache Invalidation

**Status: Confirmed working on macOS 26.2 / APFS**

A single `getattrlist()` syscall with `FSOPT_ATTR_CMN_EXTENDED` and `ATTR_CMNEXT_RECURSIVE_GENCOUNT` (0x400) returns a uint64 generation counter for any directory. This counter increments whenever any descendant file or directory is modified.

Use case: Store the gencount alongside cached scan results. On next run, compare stored gencount vs current. If unchanged, skip rescanning that subtree entirely.

```zig
// Pseudocode for cache validation
const cached_gencount = cache.read_gencount(path);
const current_gencount = getattrlist_recursive_gencount(path);
if (cached_gencount == current_gencount) {
    // Cache is fresh, skip rescan
} else {
    // Rescan this subtree only
}
```

For `--depth 3` output, this means checking ~50-200 gencounts (microseconds) instead of walking millions of inodes.

## getattrlistbulk() - Faster Tree Walk

**Status: Available, useful in native code**

macOS-specific syscall that reads attributes (name, type, size) for many directory entries in a single call. Eliminates the `readdir()` + `stat()` double-syscall-per-entry pattern.

In Zig this translates to fewer syscalls per directory. Python ctypes benchmarks showed overhead masking the benefit, but native code should see real gains since:
- 1 syscall per batch vs 2 per entry
- Kernel copies attribute data directly into the buffer
- No intermediate dirent parsing needed

## searchfs() - Catalog-Level Volume Scan

**Status: Untested, worth investigating**

macOS syscall that searches an entire volume at the APFS B-tree / catalog level, bypassing directory traversal. Could enumerate all files on a volume with sizes in one pass. This is how Spotlight builds its initial index. Potentially the fastest path for cold scans on macOS.

## What Does NOT Work

### APFS dir_stats for recursive sizes

APFS dir_stats is enabled on this system, but it does **not** expose recursive directory sizes to userspace. There is no `ATTR_CMNEXT_TOTALSIZE` or `ATTR_DIR_TOTALSIZE` in the public headers (`sys/attr.h`). The internal metadata is used by APFS for its own bookkeeping only.

### Spotlight (MDQuery / mdfind)

`kMDItemFSSize` returns null for directories. Spotlight indexes individual file metadata but does not track or aggregate directory sizes. Also skips directories with `.metadata_never_index` and may not cover all volumes.

### NSURL Resource Values

`NSURLTotalFileSizeKey` and `NSURLTotalFileAllocatedSizeKey` return nil for directories. These only work for files (total across data fork + resource fork).

## Recommended Architecture (macOS)

```
Cold scan (no cache):
  1. getattrlistbulk() tree walk with thread pool
  2. Store results + RECURSIVE_GENCOUNT per subtree in cache

Warm scan (cache exists):
  1. Check RECURSIVE_GENCOUNT for each top-level cached directory
  2. Unchanged gencount -> serve from cache (microseconds)
  3. Changed gencount -> rescan only that subtree
  4. Update cache with new results + new gencount

Future: Investigate searchfs() for even faster cold scans
```

## Tested On

- macOS 26.2 (Build 25C56)
- APFS container disk3, 2.0 TB, FileVault enabled
- All volumes APFS with dir_stats enabled
