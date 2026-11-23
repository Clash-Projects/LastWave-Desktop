import 'dart:ffi';
import 'dart:io';

typedef _SetProcessWorkingSetSizeNative = Int32 Function(
  IntPtr hProcess,
  IntPtr dwMinimumWorkingSetSize,
  IntPtr dwMaximumWorkingSetSize,
);
typedef _SetProcessWorkingSetSizeDart = int Function(
  int hProcess,
  int dwMinimumWorkingSetSize,
  int dwMaximumWorkingSetSize,
);

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

_SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;
_GetCurrentProcessDart? _getCurrentProcess;
bool _initialized = false;

void _init() {
  if (_initialized) return;
  _initialized = true;
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _getCurrentProcess = kernel32
        .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
      'GetCurrentProcess',
    );
    _setProcessWorkingSetSize = kernel32
        .lookupFunction<
          _SetProcessWorkingSetSizeNative,
          _SetProcessWorkingSetSizeDart
        >('SetProcessWorkingSetSize');
  } catch (_) {}
}

/// Trims the process working set on Windows.
/// Safely does nothing on non-Windows platforms or if FFI lookup fails.
void trimWindowsWorkingSet() {
  if (!Platform.isWindows) return;
  _init();
  try {
    final handle = _getCurrentProcess?.call() ?? -1;
    _setProcessWorkingSetSize?.call(handle, -1, -1);
  } catch (_) {}
}
