import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/platform/allocator_tuning.dart';

void main() {
  // The tuning is a best-effort FFI call, so the only thing worth locking
  // down is that the binding is real on the platforms we ship: a typo in
  // the symbol name, or switching to `DynamicLibrary.open('libc.so.6')`
  // (which is not what the engine process has loaded), would silently
  // turn the fix into a no-op with no other symptom.
  test('binds glibc mallopt on Linux', () {
    if (!Platform.isLinux) return;
    applyAllocatorTuning();
    expect(allocatorTuningApplied, isTrue,
        reason: 'mallopt(M_TRIM_THRESHOLD/M_MMAP_THRESHOLD) should be '
            'reachable on a glibc Linux host');
  });

  test('is idempotent', () {
    applyAllocatorTuning();
    final first = allocatorTuningApplied;
    applyAllocatorTuning();
    expect(allocatorTuningApplied, first);
  });
}
