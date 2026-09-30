import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Minimal Discord IPC (Rich Presence) client for Windows.
///
/// Talks to the local Discord client's named pipe (`\\.\pipe\discord-ipc-N`)
/// directly: handshake, SET_ACTIVITY, clear. No third-party package — this
/// file only uses `win32`/`ffi`, which the app already resolves.
///
/// All I/O is synchronous with tight budgets (local pipe answers in
/// milliseconds; the budgets only bite when Discord is wedged) and every
/// entry point is exception-safe: failures return false/null so callers
/// degrade to silence.
class DiscordIpc {
  static const _maxPipe = 10;
  static const _headerSize = 8;

  // Opcodes.
  static const _opHandshake = 0;
  static const _opFrame = 1;

  final HANDLE _handle;
  bool _closed = false;

  DiscordIpc._(this._handle);

  bool get isOpen => !_closed;

  /// Named-pipe IPC only exists on desktop Windows.
  static bool get isSupported => Platform.isWindows;

  /// Connects to the first responding Discord pipe and handshakes.
  /// Returns null when Discord isn't running (or vanished mid-handshake).
  /// Never throws.
  static DiscordIpc? connect(String clientId) {
    if (!Platform.isWindows) return null;
    try {
      for (var i = 0; i < _maxPipe; i++) {
        final ipc = _tryPipe('\\\\.\\pipe\\discord-ipc-$i', clientId);
        if (ipc != null) return ipc;
      }
    } catch (_) {}
    return null;
  }

  static DiscordIpc? _tryPipe(String name, String clientId) {
    final native = name.toNativeUtf16();
    HANDLE handle;
    try {
      int access = GENERIC_READ;
      access = access | GENERIC_WRITE;
      final res = CreateFile(
        PCWSTR(native),
        access,
        FILE_SHARE_NONE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
      );
      // NOTE: only the sentinel counts — GetLastError may hold a stale
      // thread error even on success.
      handle = res.value;
      if (handle == INVALID_HANDLE_VALUE) return null;
    } catch (_) {
      return null;
    } finally {
      malloc.free(native);
    }
    final ipc = DiscordIpc._(handle);
    try {
      if (!ipc._writeFrame(_opHandshake, {'v': 1, 'client_id': clientId})) {
        ipc.close();
        return null;
      }
      final reply = ipc._readFrame(budgetMs: 2000);
      if (reply != null && reply['evt'] == 'READY') return ipc;
      ipc.close();
    } catch (_) {
      ipc.close();
    }
    return null;
  }

  /// Sends the activity. Returns false on any transport failure (caller
  /// should drop and reconnect). Never throws.
  bool setActivity(Map<String, Object?> activity) {
    if (_closed) return false;
    try {
      final ok = _writeFrame(_opFrame, {
        'cmd': 'SET_ACTIVITY',
        'args': {
          'pid': pid,
          'activity': activity,
        },
        'nonce': '${DateTime.now().microsecondsSinceEpoch}',
      });
      _drain(300);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Clears the activity. Best-effort, never throws.
  bool clearActivity() {
    if (_closed) return false;
    try {
      final ok = _writeFrame(_opFrame, {
        'cmd': 'SET_ACTIVITY',
        'args': {
          'pid': pid,
          'activity': null,
        },
        'nonce': '${DateTime.now().microsecondsSinceEpoch}',
      });
      _drain(300);
      return ok;
    } catch (_) {
      return false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      CloseHandle(_handle);
    } catch (_) {}
  }

  bool _writeFrame(int opcode, Map<String, Object?> payload) {
    final data = utf8.encode(jsonEncode(payload));
    final total = _headerSize + data.length;
    final buf = calloc<Uint8>(total);
    try {
      final bytes = buf.asTypedList(total);
      bytes[0] = opcode & 0xFF;
      bytes[1] = (opcode >> 8) & 0xFF;
      bytes[2] = (opcode >> 16) & 0xFF;
      bytes[3] = (opcode >> 24) & 0xFF;
      bytes[4] = data.length & 0xFF;
      bytes[5] = (data.length >> 8) & 0xFF;
      bytes[6] = (data.length >> 16) & 0xFF;
      bytes[7] = (data.length >> 24) & 0xFF;
      bytes.setAll(_headerSize, data);
      final written = calloc<Uint32>();
      try {
        final res = WriteFile(_handle, buf, total, written, null);
        return res.value && written.value == total;
      } finally {
        calloc.free(written);
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// Reads one frame within [budgetMs], or null on timeout/garbage.
  Map<String, Object?>? _readFrame({required int budgetMs}) {
    final header = _readExact(_headerSize, budgetMs);
    if (header == null) return null;
    final len = header[4] |
        (header[5] << 8) |
        (header[6] << 16) |
        (header[7] << 24);
    if (len < 0 || len > 1024 * 1024) return null;
    final body = _readExact(len, budgetMs);
    if (body == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map<String, Object?>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Drains unread replies so the pipe buffer never fills over time.
  void _drain(int budgetMs) {
    final deadline = DateTime.now().add(Duration(milliseconds: budgetMs));
    final avail = calloc<Uint32>();
    try {
      while (!DateTime.now().isAfter(deadline)) {
        final peek = PeekNamedPipe(_handle, nullptr, 0, nullptr, avail, null);
        if (!peek.value || avail.value == 0) return;
        _readFrame(budgetMs: 200);
      }
    } catch (_) {
    } finally {
      calloc.free(avail);
    }
  }

  Uint8List? _readExact(int n, int budgetMs) {
    if (n <= 0) return Uint8List(0);
    final out = Uint8List(n);
    var got = 0;
    final deadline = DateTime.now().add(Duration(milliseconds: budgetMs));
    final avail = calloc<Uint32>();
    final chunk = calloc<Uint8>(4096);
    final read = calloc<Uint32>();
    try {
      while (got < n) {
        if (DateTime.now().isAfter(deadline)) return null;
        final peek = PeekNamedPipe(_handle, nullptr, 0, nullptr, avail, null);
        if (!peek.value) return null; // Pipe died.
        if (avail.value == 0) {
          sleep(const Duration(milliseconds: 10));
          continue;
        }
        var want = n - got;
        if (want > 4096) want = 4096;
        final res = ReadFile(_handle, chunk, want, read, null);
        if (!res.value || read.value <= 0) {
          sleep(const Duration(milliseconds: 10));
          if (DateTime.now().isAfter(deadline)) return null;
          continue;
        }
        out.setRange(got, got + read.value, chunk.asTypedList(read.value));
        got += read.value;
      }
      return out;
    } catch (_) {
      return null;
    } finally {
      calloc.free(avail);
      calloc.free(chunk);
      calloc.free(read);
    }
  }
}
