import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/presence/discord_ipc.dart';

/// Single-subscription frame reader: one listener, buffered takes.
class _Reader {
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<void>> _waiters = [];
  late final StreamSubscription<List<int>> _sub;
  bool _done = false;

  _Reader(Stream<List<int>> stream) {
    _sub = stream.listen((chunk) {
      _buf.add(chunk);
      for (final w in _waiters.toList()) {
        if (!w.isCompleted) w.complete();
      }
      _waiters.clear();
    }, onError: (_) => _finish(), onDone: _finish);
  }

  void _finish() {
    _done = true;
    for (final w in _waiters.toList()) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<Uint8List> read(int n) async {
    final deadline =
        DateTime.now().add(const Duration(seconds: 5));
    while (_buf.length < n) {
      if (_done || DateTime.now().isAfter(deadline)) {
        return Uint8List(0);
      }
      final w = Completer<void>();
      _waiters.add(w);
      try {
        await w.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        return Uint8List(0);
      }
    }
    final all = _buf.toBytes();
    _buf.clear();
    if (all.length > n) _buf.add(all.sublist(n));
    return all.sublist(0, n);
  }

  Future<void> close() async {
    try {
      await _sub.cancel();
    } catch (_) {}
  }
}

void main() {
  test('frame codec round-trips', () {
    final payload = <String, Object?>{
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': 1234, 'activity': null},
      'nonce': '1',
    };
    final frame = DiscordIpc.encodeFrame(1, payload);
    final view = ByteData.sublistView(frame);
    expect(view.getInt32(0, Endian.little), 1);
    expect(view.getInt32(4, Endian.little), frame.length - 8);
    final back =
        DiscordIpc.decodeFrame(frame.sublist(8));
    expect(back?['cmd'], 'SET_ACTIVITY');
    expect((back?['args'] as Map)['pid'], 1234);
  });

  test('socket candidates include the runtime dir', () {
    final paths = DiscordIpc.socketCandidates();
    expect(paths, isNotEmpty);
    expect(paths.any((p) => p.endsWith('/discord-ipc-0')), isTrue);
  });

  test(
    'unix socket handshake loopback',
    () async {
      final dir =
          await Directory.systemTemp.createTemp('discord_ipc_test');
      try {
        final path = '${dir.path}/discord-ipc-9';
        final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        try {
          // Fake Discord: read one handshake frame, reply READY.
          server.listen((client) async {
            final reader = _Reader(client);
            try {
              final header = await reader.read(8);
              expect(header.length, 8);
              final len = ByteData.sublistView(header)
                  .getInt32(4, Endian.little);
              final body = await reader.read(len);
              final req = DiscordIpc.decodeFrame(body);
              expect(req?['client_id'], 'probe-id');
              client.add(DiscordIpc.encodeFrame(
                  1, {'evt': 'READY', 'data': {}}));
            } finally {
              await reader.close();
            }
          });

          final client = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
            timeout: const Duration(seconds: 5),
          );
          final reader = _Reader(client);
          try {
            client.add(DiscordIpc.encodeFrame(
                0, {'v': 1, 'client_id': 'probe-id'}));
            final header = await reader.read(8);
            expect(header.length, 8);
            final len = ByteData.sublistView(header)
                .getInt32(4, Endian.little);
            final body = await reader.read(len);
            expect(
                DiscordIpc.decodeFrame(body)?['evt'], 'READY');
          } finally {
            await reader.close();
            client.destroy();
          }
        } finally {
          await server.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
