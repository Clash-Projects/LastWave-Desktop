import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Minimal Discord IPC (Rich Presence) client for desktop.
///
/// Talks to the local Discord client directly: named pipes
/// (`\\.\pipe\discord-ipc-N`) on Windows, Unix domain sockets
/// (`discord-ipc-N` under `$XDG_RUNTIME_DIR`, `/tmp`, …) on
/// Linux/macOS. Handshake, SET_ACTIVITY, clear — no third-party
/// package (`win32`/`ffi` on Windows, `dart:io` sockets elsewhere).
///
/// Every entry point is exception-safe: failures return false/null so
/// callers degrade to silence.
abstract class DiscordIpc {
  static const _maxPipe = 10;

  // Opcodes.
  static const _opHandshake = 0;
  static const _opFrame = 1;

  bool get isOpen;

  /// Named pipes (Windows) or Unix sockets (Linux/macOS) only.
  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Connects to the first responding Discord endpoint and handshakes.
  /// Returns null when Discord isn't running (or vanished mid-handshake).
  /// Never throws.
  static Future<DiscordIpc?> connect(String clientId) async {
    try {
      if (Platform.isWindows) {
        for (var i = 0; i < _maxPipe; i++) {
          final ipc = _WindowsIpc.tryPipe(
              '\\\\.\\pipe\\discord-ipc-$i', clientId);
          if (ipc != null) return ipc;
        }
        return null;
      }
      for (final path in _socketCandidates()) {
        final ipc = await _UnixIpc.trySocket(path, clientId);
        if (ipc != null) return ipc;
      }
    } catch (_) {}
    return null;
  }

  /// Unix socket search order per Discord spec: env runtime dirs,
  /// `/run/user/<uid>/*`, then `/tmp`. Never throws.
  static List<String> socketCandidates() {
    try {
      return _socketCandidates();
    } catch (_) {
      return const [];
    }
  }

  static List<String> _socketCandidates() {
    final dirs = <String>[];
    void add(String? dir) {
      if (dir == null || dir.isEmpty || dirs.contains(dir)) return;
      dirs.add(dir);
    }

    final env = Platform.environment;
    add(env['XDG_RUNTIME_DIR']);
    add(env['TMPDIR']);
    add(env['TMP']);
    add(env['TEMP']);
    // UID-indexed runtime dir when the env var is absent (ssh, systemd
    // units, …). Listing /run/user is world-readable on stock distros.
    try {
      final runUser = Directory('/run/user');
      if (runUser.existsSync()) {
        for (final e in runUser.listSync(followLinks: false)) {
          if (e is Directory) add(e.path);
        }
      }
    } catch (_) {}
    add('/tmp');
    final out = <String>[];
    for (final dir in dirs) {
      for (var i = 0; i < _maxPipe; i++) {
        out.add('$dir/discord-ipc-$i');
      }
    }
    return out;
  }

  /// Sends the activity. Returns false on any transport failure (caller
  /// should drop and reconnect). Never throws.
  bool setActivity(Map<String, Object?> activity);

  /// Clears the activity. Best-effort, never throws.
  bool clearActivity();

  void close();

  /// Shared frame codec: int32LE opcode + int32LE length + JSON.
  /// Exactly what both transports (and the loopback test) use.
  static Uint8List encodeFrame(int opcode, Map<String, Object?> payload) {
    final data = utf8.encode(jsonEncode(payload));
    final total = 8 + data.length;
    final bytes = Uint8List(total);
    final view = ByteData.sublistView(bytes);
    view.setInt32(0, opcode, Endian.little);
    view.setInt32(4, data.length, Endian.little);
    bytes.setAll(8, data);
    return bytes;
  }

  static Map<String, Object?>? decodeFrame(Uint8List body) {
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map<String, Object?>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Windows named-pipe transport. Synchronous I/O with tight budgets
/// (local pipe answers in milliseconds).
class _WindowsIpc extends DiscordIpc {
  static const _headerSize = 8;

  final HANDLE _handle;
  bool _closed = false;

  _WindowsIpc._(this._handle);

  @override
  bool get isOpen => !_closed;

  static _WindowsIpc? tryPipe(String name, String clientId) {
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
    final ipc = _WindowsIpc._(handle);
    try {
      if (!ipc._writeFrame(
          DiscordIpc._opHandshake, {'v': 1, 'client_id': clientId})) {
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

  @override
  bool setActivity(Map<String, Object?> activity) {
    if (_closed) return false;
    try {
      final ok = _writeFrame(DiscordIpc._opFrame, {
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

  @override
  bool clearActivity() {
    if (_closed) return false;
    try {
      final ok = _writeFrame(DiscordIpc._opFrame, {
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

  @override
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

/// Unix-domain-socket transport (Linux/macOS). Discord listens on
/// `discord-ipc-N` inside the runtime dir; same 8-byte frame codec as
/// the pipe transport. Async I/O with tight budgets; never throws.
class _UnixIpc extends DiscordIpc {
  final Socket _socket;
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<void>> _waiters = [];
  StreamSubscription<List<int>>? _sub;
  bool _closed = false;
  bool _done = false;

  _UnixIpc._(this._socket);

  @override
  bool get isOpen => !_closed;

  /// Single persistent subscription: Unix sockets are
  /// single-subscription streams, so one listener feeds a buffer that
  /// every read takes from. (A fresh listen per read throws.)
  void _attach() {
    _sub ??= _socket.listen((chunk) {
      _buf.add(chunk);
      for (final w in _waiters.toList()) {
        if (!w.isCompleted) w.complete();
      }
      _waiters.clear();
    }, onError: (_) => _finish(), onDone: () => _finish(),
        cancelOnError: true);
  }

  void _finish() {
    _done = true;
    for (final w in _waiters.toList()) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  static Future<_UnixIpc?> trySocket(String path, String clientId) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 2),
      );
    } catch (_) {
      return null;
    }
    final ipc = _UnixIpc._(socket);
    try {
      await ipc._writeFrame(
          DiscordIpc._opHandshake, {'v': 1, 'client_id': clientId});
      // Discord's IPC latency varies wildly (observed 0.4s–1.8s,
      // occasional never; reconnect storms make it worse). 5s catches
      // slow answers; the service's 15s retry throttle is the real
      // recovery for hung attempts, re-trying while music plays.
      final reply = await ipc._readFrame(
          budget: const Duration(seconds: 5));
      if (reply != null && reply['evt'] == 'READY') return ipc;
      ipc.close();
    } catch (_) {
      ipc.close();
    }
    return null;
  }

  @override
  bool setActivity(Map<String, Object?> activity) {
    if (_closed) return false;
    try {
      _socket.add(DiscordIpc.encodeFrame(DiscordIpc._opFrame, {
        'cmd': 'SET_ACTIVITY',
        'args': {
          'pid': pid,
          'activity': activity,
        },
        'nonce': '${DateTime.now().microsecondsSinceEpoch}',
      }));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool clearActivity() {
    if (_closed) return false;
    try {
      _socket.add(DiscordIpc.encodeFrame(DiscordIpc._opFrame, {
        'cmd': 'SET_ACTIVITY',
        'args': {
          'pid': pid,
          'activity': null,
        },
        'nonce': '${DateTime.now().microsecondsSinceEpoch}',
      }));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _finish();
    try {
      _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      _socket.destroy();
    } catch (_) {}
  }

  Future<void> _writeFrame(
      int opcode, Map<String, Object?> payload) async {
    _socket.add(DiscordIpc.encodeFrame(opcode, payload));
    await _socket.flush().timeout(const Duration(seconds: 2));
  }

  /// Reads one frame within [budget], or null on timeout/garbage.
  Future<Map<String, Object?>?> _readFrame(
      {required Duration budget}) async {
    final header = await _readExact(8, budget);
    if (header == null) return null;
    final view = ByteData.sublistView(header);
    final len = view.getInt32(4, Endian.little);
    if (len < 0 || len > 1024 * 1024) return null;
    final body = await _readExact(len, budget);
    if (body == null) return null;
    return DiscordIpc.decodeFrame(body);
  }

  Future<Uint8List?> _readExact(int n, Duration budget) async {
    if (n <= 0) return Uint8List(0);
    _attach();
    final deadline = DateTime.now().add(budget);
    while (_buf.length < n) {
      if (_done || _closed || DateTime.now().isAfter(deadline)) {
        return null;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      try {
        await waiter.future.timeout(budget);
      } catch (_) {
        return null;
      }
    }
    final all = _buf.toBytes();
    _buf.clear();
    if (all.length > n) _buf.add(all.sublist(n));
    return all.sublist(0, n);
  }
}
