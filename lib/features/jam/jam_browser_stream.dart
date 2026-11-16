import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/network/dio_factory.dart';
import '../innertube/innertube_api.dart';
import 'jam_client.dart';

/// Above this many browser guests the host's upload starts to matter.
const jamBrowserGuestWarnAt = 8;

const _maxGuests = 30;
const _chunk = 16 * 1024;
const _range = 512 * 1024;
const _maxBuffered = 1024 * 1024;
const _ice = {
  'iceServers': [
    {
      'urls': ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'],
    },
  ],
};
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

class JamBrowserState {
  final bool on;

  /// Browser guests with a live peer-to-peer connection.
  final int connected;
  const JamBrowserState({this.on = false, this.connected = 0});
}

class _Guest {
  final RTCPeerConnection pc;
  final RTCDataChannel dc;
  Future<void> chain = Future.value(); // one file at a time per guest
  _Guest(this.pc, this.dc);
}

/// A song being fetched in ranges, shared by every guest that wants it.
class _SongFile {
  final chunks = <Uint8List>[];
  int size = 0;
  String mime = 'audio/mp4';
  bool done = false;
  bool failed = false;
  Completer<void> _tick = Completer();
  Future<void> get changed => _tick.future;
  void notify() {
    final t = _tick;
    _tick = Completer();
    t.complete();
  }
}

/// Host side of Jam "Browser Guest Mode".
///
/// Browser guests get the YouTube version (M4A AAC, ~128 kbps) of the
/// room's current and next song, whatever the host itself plays (lossless,
/// exclusive, local). The host fetches each file once and sends it over a
/// WebRTC data channel per guest; the page plays it on the room clock.
/// Only SDP goes through the Jam server, so no audio touches the VPS.
class JamBrowserStream extends StateNotifier<JamBrowserState> {
  JamBrowserStream(this._ref) : super(const JamBrowserState()) {
    _ref.listen<JamSnapshot>(jamControllerProvider, (prev, next) {
      final lost = next.phase != JamPhase.active ||
          !next.isMainHost ||
          next.radio ||
          next.permanent ||
          (prev?.webGuests == true && !next.webGuests);
      if (state.on && lost) {
        stop(tellServer: false);
        return;
      }
      // Fetch the current and next song ahead of time so guests switch
      // tracks without waiting on YouTube.
      if (state.on && _guests.isNotEmpty) {
        for (final id in [next.track?.id, next.queue.firstOrNull?.id]) {
          if (id != null && _allowed(id)) _song(id);
        }
      }
    });
    _signals = _jam.rtcSignals.listen((s) {
      if (state.on) _onSignal(s);
    });
  }

  final Ref _ref;
  late final StreamSubscription<JamRtcSignal> _signals;
  final _guests = <String, _Guest>{};
  final _files = <String, _SongFile>{};
  final Dio _dio = DioFactory.create();

  JamController get _jam => _ref.read(jamControllerProvider.notifier);

  void start() {
    if (state.on) return;
    _jam.setWebGuests(true);
    state = const JamBrowserState(on: true);
  }

  Future<void> stop({bool tellServer = true}) async {
    final wasOn = state.on;
    state = const JamBrowserState();
    for (final id in _guests.keys.toList()) {
      await _close(id, bye: true);
    }
    _files.clear();
    if (tellServer && wasOn) _jam.setWebGuests(false);
  }

  void _report() {
    if (!state.on) return;
    final n = _guests.values
        .where((g) =>
            g.pc.connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateConnected)
        .length;
    state = JamBrowserState(on: true, connected: n);
  }

  Future<void> _onSignal(JamRtcSignal s) async {
    switch (s.data['kind']) {
      case 'hello':
        await _hello(s.from);
      case 'answer':
        final sdp = s.data['sdp']?.toString() ?? '';
        final g = _guests[s.from];
        if (g == null || sdp.isEmpty) return;
        try {
          await g.pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        } catch (_) {
          await _close(s.from, bye: true);
        }
      case 'bye':
        await _close(s.from);
    }
  }

  Future<void> _hello(String id) async {
    await _close(id);
    if (_guests.length >= _maxGuests) {
      _jam.sendRtcSignal(id, const {'kind': 'bye', 'reason': 'busy'});
      return;
    }
    try {
      final pc = await createPeerConnection(_ice);
      final dc = await pc.createDataChannel('song', RTCDataChannelInit());
      final guest = _Guest(pc, dc);
      _guests[id] = guest;
      dc.onMessage = (m) {
        if (!m.isBinary) _onGuestMessage(id, guest, m.text);
      };
      pc.onConnectionState = (s) {
        if (_guests[id] != guest) return;
        // A guest whose network blocks P2P fails alone; nobody else is touched.
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _close(id);
        } else {
          _report();
        }
      };
      // Non-trickle ICE: one offer message per guest keeps signaling tiny.
      final gathered = Completer<void>();
      pc.onIceGatheringState = (s) {
        if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !gathered.isCompleted) {
          gathered.complete();
        }
      };
      await pc.setLocalDescription(await pc.createOffer());
      await gathered.future
          .timeout(const Duration(seconds: 3), onTimeout: () {});
      final local = await pc.getLocalDescription();
      if (_guests[id] != guest || local?.sdp == null) return;
      _jam.sendRtcSignal(id, {'kind': 'offer', 'sdp': local!.sdp});
      _report();
    } catch (_) {
      await _close(id, bye: true);
    }
  }

  Future<void> _close(String id, {bool bye = false}) async {
    final g = _guests.remove(id);
    if (g == null) return;
    if (bye) _jam.sendRtcSignal(id, const {'kind': 'bye'});
    try {
      await g.dc.close();
      await g.pc.close();
    } catch (_) {}
    _report();
  }

  void _onGuestMessage(String id, _Guest guest, String text) {
    final Map m;
    try {
      m = jsonDecode(text) as Map;
    } catch (_) {
      return;
    }
    final song = m['id']?.toString() ?? '';
    if (m['kind'] != 'get' || song.isEmpty) return;
    guest.chain = guest.chain.then((_) => _sendSong(id, guest, song));
  }

  /// Only the room's current and queued songs: guests can't make the host
  /// fetch arbitrary videos.
  bool _allowed(String song) {
    final jam = _ref.read(jamControllerProvider);
    return _videoId.hasMatch(song) &&
        (jam.track?.id == song || jam.queue.any((t) => t.id == song));
  }

  Future<void> _sendSong(String id, _Guest guest, String song) async {
    bool gone() => _guests[id] != guest;
    Future<void> text(Map<String, dynamic> m) =>
        guest.dc.send(RTCDataChannelMessage(jsonEncode(m)));
    try {
      // Local files and lossless-only songs use their title as the room id,
      // so there is no YouTube video to send. Say so instead of retrying.
      if (!_videoId.hasMatch(song)) {
        return await text(
            {'kind': 'missing', 'id': song, 'reason': 'no_youtube'});
      }
      final file = _allowed(song) ? _song(song) : null;
      while (file != null && file.size == 0 && !file.failed) {
        await file.changed;
      }
      if (gone()) return;
      if (file == null || file.failed && file.size == 0) {
        return await text({'kind': 'missing', 'id': song});
      }
      await text({
        'kind': 'file',
        'id': song,
        'size': file.size,
        'mime': file.mime,
      });
      // Relay each 512 KB range as it lands, so guests start playing
      // after the first chunk instead of the whole file.
      for (var i = 0;; i++) {
        while (i >= file.chunks.length && !file.done && !file.failed) {
          await file.changed;
        }
        if (gone()) return;
        // The room moved on (skip): free this guest for the song it needs now.
        if (!_allowed(song)) return;
        if (i >= file.chunks.length) break;
        final bytes = file.chunks[i];
        for (var at = 0; at < bytes.length; at += _chunk) {
          // Pace on the SCTP buffer: libwebrtc closes a channel that overfills.
          while (await guest.dc.getBufferedAmount() > _maxBuffered) {
            if (gone()) return;
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          final end = at + _chunk < bytes.length ? at + _chunk : bytes.length;
          await guest.dc.send(RTCDataChannelMessage.fromBinary(
              Uint8List.sublistView(bytes, at, end)));
        }
      }
      await text({'kind': file.done ? 'end' : 'missing', 'id': song});
    } catch (_) {}
  }

  /// One fetch per song shared by every guest; keeps the last few.
  _SongFile _song(String song) {
    final hit = _files[song];
    // A failed fetch (even a partial one) is retried from scratch.
    if (hit != null && !hit.failed) return hit;
    if (_files.length >= 4) _files.remove(_files.keys.first);
    final file = _files[song] = _SongFile();
    unawaited(_fetch(song, file));
    return file;
  }

  /// YouTube in bounded 512 KB ranges: open-ended ranges get a 403
  /// mid-song. Download-optimized pick prefers M4A AAC (~128 kbps), which
  /// plays in every browser including Safari.
  Future<void> _fetch(String song, _SongFile file) async {
    try {
      // The resolver walks every YouTube client after a 30 s script fetch;
      // cap it so a hard song fails fast and the guest can retry.
      final stream = await _ref
          .read(innerTubeProvider)
          .resolveDownloadStream(song)
          .timeout(const Duration(seconds: 25));
      if (stream == null || !stream.url.startsWith('http')) {
        throw StateError('no stream');
      }
      file.mime = stream.mimeType;
      var at = 0;
      var total = 1;
      while (at < total) {
        // Evicted or stopped: fail so waiting senders wake up and finish.
        if (_files[song] != file) throw StateError('evicted');
        Response<List<int>>? res;
        for (var attempt = 0; res == null; attempt++) {
          try {
            res = await _dio.get<List<int>>(
              stream.url,
              options: Options(
                responseType: ResponseType.bytes,
                headers: {
                  ...stream.requestHeaders,
                  'Range': 'bytes=$at-${at + _range - 1}',
                },
              ),
            );
          } catch (_) {
            if (attempt >= 2) rethrow;
          }
        }
        final data = res.data ?? const <int>[];
        if (data.isEmpty) throw StateError('empty range');
        // "bytes 0-524287/4031220"; a 200 without it is the whole file.
        final range = res.headers.value('content-range') ?? '';
        final slash = range.lastIndexOf('/');
        total = res.statusCode == 206 && slash >= 0
            ? int.tryParse(range.substring(slash + 1)) ?? at + data.length
            : data.length;
        if (file.size == 0) file.size = total;
        file.chunks.add(Uint8List.fromList(data));
        at += data.length;
        file.notify();
        if (res.statusCode != 206) break;
      }
      file.done = true;
    } catch (_) {
      file.failed = true;
    }
    file.notify();
  }

  @override
  void dispose() {
    _signals.cancel();
    stop(tellServer: false);
    super.dispose();
  }
}

final jamBrowserStreamProvider =
    StateNotifierProvider<JamBrowserStream, JamBrowserState>(
        (ref) => JamBrowserStream(ref));
