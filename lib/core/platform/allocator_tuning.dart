import 'dart:ffi';
import 'dart:io';

/// Freeze glibc's *dynamic* `mmap` / `trim` thresholds at their defaults.
///
/// glibc starts with `mmap_threshold = 128 KiB`: allocations at or above
/// it are `mmap`'d, and `free` `munmap`s them, so the pages go straight
/// back to the OS. That is the right behaviour for libmpv, which
/// allocates multi-MB buffers every time a track is opened (demuxer
/// cache, back buffer, decoder pools) and frees them again on the next.
///
/// Both thresholds are *dynamic*, though: freeing an `mmap`'d block
/// raises `mmap_threshold` to that block's size (capped at 32 MiB) and
/// `trim_threshold` to twice that. So the first 16 MiB demuxer cache is
/// returned to the OS and every one after it is served from the heap —
/// where `free` only returns pages once the free space at the top of the
/// heap exceeds `trim_threshold`, which by then has also grown (to
/// ~32 MiB). The heap therefore grows to fit the largest buffer the
/// process ever asked for and keeps it for the run, while track after
/// track churns fresh buffers on top of it.
///
/// Measured on this app before the change: `[mem]` showed +80 MB of RSS
/// per track change with `RssAnon` climbing 94 → 405 MB, while `RssFile`
/// stayed flat at ~228 MB, the Dart heap sat at 15–68 MB
/// (`heapUsage/heapCapacity`, still oscillating → GC healthy) and every
/// other Dart-side counter was flat. The tell was `malloc_trim(0)`
/// handing back 18–58 MB on every sample: the allocator was sitting on
/// freed native pages. Ambient mode off made no difference, and the climb
/// continued identically while the window was minimised (`view=4x2`,
/// zero live images, no rendering) — so it is playback-driven native
/// churn, not artwork or Impeller.
///
/// `mallopt` sets both values and (per glibc's `do_set_*_threshold`) also
/// sets `no_dyn_threshold`, switching the adaptation off, so big buffers
/// are `mmap`'d and returned from then on. Reproduced in isolation
/// (48 KiB ballast, churning 2–20 MiB buffers through malloc/free in a
/// loop): default held a +20 MB high-water mark, tuned stayed flat within
/// ±1 MB.
///
/// The cost is extra `mmap`/`munmap` syscalls for large allocations.
/// Those are per track, not per frame, so it is noise next to the network
/// and JSON work a track change already does — and nothing here touches
/// small allocations, which stay on glibc's fast arena path.
///
/// Linux-only and entirely best-effort: off Linux, or on a libc that does
/// not export `mallopt` (musl), this is a no-op. The revert is deleting
/// the call in `main.dart`.
void applyAllocatorTuning() {
  if (_applied) return;
  _applied = true;
  if (!Platform.isLinux) return;
  try {
    final mallopt = DynamicLibrary.process()
        .lookupFunction<_MalloptNative, _MalloptDart>('mallopt');
    // Exactly glibc's own starting values — this freezes them rather than
    // moving them, so small-allocation behaviour is unchanged.
    const threshold = 128 * 1024;
    const trimThreshold = -1;
    const mmapThreshold = -3;
    _succeeded = mallopt(trimThreshold, threshold) != 0 &&
        mallopt(mmapThreshold, threshold) != 0;
  } catch (_) {
    // Not glibc, or the symbol is not exported — leave the allocator
    // exactly as it was.
  }
}

/// Whether [applyAllocatorTuning] actually reached a libc `mallopt`
/// (Linux + glibc only). Nothing branches on this at runtime; it exists
/// so the binding can be asserted instead of assumed.
bool get allocatorTuningApplied => _succeeded;

bool _applied = false;
bool _succeeded = false;

typedef _MalloptNative = Int32 Function(Int32, Int32);
typedef _MalloptDart = int Function(int, int);
