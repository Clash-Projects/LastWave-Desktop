import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

const jamDefaultServer = 'wss://jam.clashprojects.qd.je/ws';

/// "3:42:10 PM" for a wall-clock millisecond timestamp.
String jamClock(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$h:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

const jamModeCollaborative = 'collaborative';
const jamModeHostOnly = 'host_only';

/// Always-active stations. The server provisions these and never closes them.
const jamStations = <JamStation>[
  JamStation(code: 'INDIA', title: 'India', blurb: 'Always-on room for India'),
  JamStation(
    code: 'WORLD',
    title: 'International',
    blurb: 'Always-on room for everyone else',
  ),
];

class JamStation {
  final String code;
  final String title;
  final String blurb;
  const JamStation({
    required this.code,
    required this.title,
    required this.blurb,
  });
}

class JamPerson {
  final String userId;
  final String name;

  /// True for the main host and the co-host.
  final bool isHost;
  final bool isCoHost;
  const JamPerson({
    required this.userId,
    required this.name,
    this.isHost = false,
    this.isCoHost = false,
  });
}

/// Snapshot of the message a chat line replies to.
class JamReply {
  final String id;
  final String userName;
  final String text;
  const JamReply({
    required this.id,
    required this.userName,
    required this.text,
  });
}

class JamChatLine {
  final String id;
  final String userId;
  final String userName;
  final bool isHost;
  final String text;
  final int timestamp;
  final JamReply? replyTo;
  const JamChatLine({
    required this.id,
    required this.userId,
    required this.userName,
    required this.text,
    this.isHost = false,
    this.timestamp = 0,
    this.replyTo,
  });
}

class JamTrack {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? artworkUrl;
  final int? durationMs;
  const JamTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.artworkUrl,
    this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'artwork_url': artworkUrl,
        'duration_ms': durationMs,
      };

  factory JamTrack.fromJson(Map<String, dynamic> json) => JamTrack(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        album: json['album']?.toString(),
        artworkUrl: json['artwork_url']?.toString(),
        durationMs: json['duration_ms'] is num
            ? (json['duration_ms'] as num).toInt()
            : int.tryParse('${json['duration_ms'] ?? ''}'),
      );
}

sealed class JamRemote {
  const JamRemote();
}

class JamRemotePlay extends JamRemote {
  final int positionMs;
  final int serverTimeMs;
  final String? fromUserId;
  const JamRemotePlay(this.positionMs, this.serverTimeMs, this.fromUserId);
}

class JamRemotePause extends JamRemote {
  final int positionMs;
  final String? fromUserId;
  const JamRemotePause(this.positionMs, this.fromUserId);
}

class JamRemoteSeek extends JamRemote {
  final int positionMs;
  final String? fromUserId;
  const JamRemoteSeek(this.positionMs, this.fromUserId);
}

class JamRemoteTrack extends JamRemote {
  final JamTrack track;
  final bool isPlaying;
  final int positionMs;
  final String? fromUserId;
  const JamRemoteTrack(
    this.track,
    this.isPlaying,
    this.positionMs,
    this.fromUserId,
  );
}

class JamRemoteFull extends JamRemote {
  final JamTrack? track;
  final bool isPlaying;
  final int positionMs;
  final int serverTimeMs;
  const JamRemoteFull({
    required this.track,
    required this.isPlaying,
    required this.positionMs,
    required this.serverTimeMs,
  });
}

enum JamPhase { disconnected, connecting, active, error }

class JamSnapshot {
  final JamPhase phase;
  final String error;
  final String roomCode;
  final String userId;
  final String displayName;
  final bool isHost;
  final String hostId;
  final String coHostId;
  final bool permanent;

  /// Always-on rooms are 24/7 radio stations driven by the server.
  final bool radio;

  /// Station on auto radio (true) or run by a station admin (false).
  final bool stationAuto;
  final String roomMode;
  final List<JamPerson> people;
  final List<JamChatLine> chat;
  final JamTrack? track;
  final bool isPlaying;

  /// The admin's upcoming queue, shared read-only with the room.
  final List<JamTrack> queue;

  /// Friendly title of an always-on room ("India"); empty otherwise.
  final String roomName;

  /// Wall-clock ms until which pause/skip are locked for you; 0 when free.
  final int cooldownUntilMs;

  /// Transient message from the server (rate limit, host rules).
  final String notice;

  /// Wall-clock ms when the playback cooldown ends; 0 when none.
  final int retryAtMs;

  /// True only for the main host, who may give and remove co-hosts.
  bool get isMainHost => userId.isNotEmpty && userId == hostId;

  /// A listener on a live station: no playback control at all.
  bool get isStationListener => phase == JamPhase.active && radio && !isHost;

  const JamSnapshot({
    this.phase = JamPhase.disconnected,
    this.error = '',
    this.roomCode = '',
    this.userId = '',
    this.displayName = '',
    this.isHost = false,
    this.hostId = '',
    this.coHostId = '',
    this.permanent = false,
    this.radio = false,
    this.stationAuto = true,
    this.roomMode = jamModeCollaborative,
    this.people = const [],
    this.chat = const [],
    this.track,
    this.isPlaying = false,
    this.queue = const [],
    this.roomName = '',
    this.cooldownUntilMs = 0,
    this.notice = '',
    this.retryAtMs = 0,
  });

  JamSnapshot copyWith({
    JamPhase? phase,
    String? error,
    String? roomCode,
    String? userId,
    String? displayName,
    bool? isHost,
    String? hostId,
    String? coHostId,
    bool? permanent,
    bool? radio,
    bool? stationAuto,
    String? roomMode,
    List<JamPerson>? people,
    List<JamChatLine>? chat,
    JamTrack? track,
    bool clearTrack = false,
    bool? isPlaying,
    List<JamTrack>? queue,
    String? roomName,
    int? cooldownUntilMs,
    String? notice,
    int? retryAtMs,
  }) =>
      JamSnapshot(
        phase: phase ?? this.phase,
        error: error ?? this.error,
        roomCode: roomCode ?? this.roomCode,
        userId: userId ?? this.userId,
        displayName: displayName ?? this.displayName,
        isHost: isHost ?? this.isHost,
        hostId: hostId ?? this.hostId,
        coHostId: coHostId ?? this.coHostId,
        permanent: permanent ?? this.permanent,
        radio: radio ?? this.radio,
        stationAuto: stationAuto ?? this.stationAuto,
        roomMode: roomMode ?? this.roomMode,
        people: people ?? this.people,
        chat: chat ?? this.chat,
        track: clearTrack ? null : (track ?? this.track),
        isPlaying: isPlaying ?? this.isPlaying,
        queue: queue ?? this.queue,
        roomName: roomName ?? this.roomName,
        cooldownUntilMs: cooldownUntilMs ?? this.cooldownUntilMs,
        notice: notice ?? this.notice,
        retryAtMs: retryAtMs ?? this.retryAtMs,
      );
}

/// WebSocket client for the Clash Projects Jam server.
///
/// A failed connection sets [JamPhase.error] and does not touch playback.
bool _isDefaultName(String name) => const {
      '',
      'listener',
      'host',
      'guest',
      'user',
      'anonymous',
    }.contains(name.trim().toLowerCase());

class JamController extends StateNotifier<JamSnapshot> {
  JamController(this._ref) : super(const JamSnapshot());

  final Ref _ref;
  WebSocket? _socket;
  Timer? _ping;
  final _remote = StreamController<JamRemote>.broadcast();
  int _generation = 0;

  Stream<JamRemote> get remote => _remote.stream;

  String get serverUrl {
    final raw = _ref.read(prefsProvider).jamServerUrl.trim();
    return raw.isEmpty ? jamDefaultServer : raw;
  }

  /// Shareable https link; opens the web invite page, which launches
  /// whichever LastWave (desktop or Android) is installed and previews with
  /// the room code in chat apps.
  String inviteLink(String code) {
    final u = Uri.parse(serverUrl);
    final base = Uri(
      scheme: u.scheme == 'wss' ? 'https' : 'http',
      host: u.host,
      port: u.hasPort ? u.port : null,
    );
    return '$base/?code=$code';
  }

  /// Accepts a bare code or a pasted invite link (`...?code=ABC123`).
  static String parseCode(String raw) {
    final text = raw.trim();
    final at = text.toLowerCase().indexOf('code=');
    final tail = at >= 0 ? text.substring(at + 5) : text;
    return tail.split(RegExp(r'[&#\s]')).first.trim().toUpperCase();
  }

  void createRoom(String displayName, {required bool collaborative}) {
    final name = displayName.trim().isEmpty ? 'Listener' : displayName.trim();
    _connect(() {
      _send('create_room', {
        'name': name,
        'room_mode': collaborative ? jamModeCollaborative : jamModeHostOnly,
      });
    });
  }

  void joinRoom(String roomCode, String displayName) {
    final code = parseCode(roomCode);
    final name = displayName.trim().isEmpty ? 'Listener' : displayName.trim();
    if (code.isEmpty) {
      state = state.copyWith(
        phase: JamPhase.error,
        error: 'Room code is required',
      );
      return;
    }
    if (jamStations.any((s) => s.code == code) && _isDefaultName(displayName)) {
      state = state.copyWith(
        phase: JamPhase.error,
        error: 'Pick your own display name to join this public room',
      );
      return;
    }
    _connect(() {
      _send('join_room', {'room_code': code, 'name': name});
    }, code: code);
  }

  void leave() {
    _send('leave_room', null);
    _close(clear: true);
  }

  void sendChat(String text, {String? replyToId}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _send('send_chat', {
      'text': trimmed,
      if (replyToId != null && replyToId.isNotEmpty) 'reply_to_id': replyToId,
    });
  }

  /// Main host only: make [userId] a co-host (a room has at most two hosts).
  void grantHost(String userId) => _send('grant_host', {'user_id': userId});

  /// Station admin only: hand the station to someone else.
  void transferAdmin(String userId) =>
      _send('transfer_host', {'user_id': userId});

  /// Main host only: remove [userId]'s co-host role.
  void revokeHost(String userId) => _send('revoke_host', {'user_id': userId});

  /// Main host only: publish the upcoming queue so listeners can see it.
  void broadcastQueue(List<JamTrack> queue) {
    if (state.phase != JamPhase.active) return;
    _send('queue_update', {
      'queue': [for (final t in queue.take(5)) t.toJson()],
    });
  }

  List<JamTrack> _tracks(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          JamTrack.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
    ];
  }

  Timer? _cooldownTimer;

  /// Locks pause/skip until [untilMs] and unlocks them automatically.
  void _startCooldown(int untilMs) {
    final wait = untilMs - DateTime.now().millisecondsSinceEpoch;
    if (wait <= 0) return;
    state = state.copyWith(cooldownUntilMs: untilMs);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(Duration(milliseconds: wait + 100), () {
      if (state.cooldownUntilMs == untilMs) {
        state = state.copyWith(cooldownUntilMs: 0);
      }
    });
  }

  /// Live listener counts for the always-on rooms ({code: count}).
  /// Empty on any failure; the join screen then just omits the counts.
  Future<Map<String, int>> fetchRoomCounts() async {
    try {
      final uri = Uri.parse(serverUrl);
      final http = Uri(
        scheme: uri.scheme == 'wss' ? 'https' : 'http',
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: '/rooms',
      );
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(http);
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) return const {};
        final body = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        final rooms = decoded is Map ? decoded['rooms'] : null;
        if (rooms is! List) return const {};
        return {
          for (final r in rooms)
            if (r is Map) r['code'].toString(): _int(r['participants']),
        };
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return const {};
    }
  }

  void clearNotice() {
    if (state.notice.isEmpty && state.retryAtMs == 0) return;
    state = state.copyWith(notice: '', retryAtMs: 0);
  }

  void broadcastPlay(int positionMs) => _action({
        'action': 'play',
        'position_ms': positionMs,
        'client_time_ms': DateTime.now().millisecondsSinceEpoch,
        'is_playing': true,
      });

  void broadcastPause(int positionMs) => _action({
        'action': 'pause',
        'position_ms': positionMs,
        'client_time_ms': DateTime.now().millisecondsSinceEpoch,
        'is_playing': false,
      });

  void broadcastSeek(int positionMs) => _action({
        'action': 'seek',
        'position_ms': positionMs,
        'client_time_ms': DateTime.now().millisecondsSinceEpoch,
      });

  void broadcastTrack(JamTrack track, {required int positionMs, required bool isPlaying}) {
    _action({
      'action': 'change_track',
      'track': track.toJson(),
      'position_ms': positionMs,
      'client_time_ms': DateTime.now().millisecondsSinceEpoch,
      'is_playing': isPlaying,
    });
  }

  void _action(Map<String, dynamic> payload) {
    if (state.phase != JamPhase.active) return;
    _send('playback_action', payload);
  }

  Future<void> _connect(void Function() onOpen, {String? code}) async {
    final generation = ++_generation;
    await _close(clear: false);
    state = JamSnapshot(
      phase: JamPhase.connecting,
      roomCode: code ?? '',
    );
    final url = serverUrl;
    try {
      final socket = await WebSocket.connect(url).timeout(
        const Duration(seconds: 12),
      );
      if (generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 25), (_) {
        _send('ping', null);
      });
      socket.listen(
        (data) {
          if (data is String) _onMessage(data);
        },
        onError: (Object error) {
          if (generation != _generation) return;
          state = state.copyWith(
            phase: JamPhase.error,
            error: error.toString(),
          );
        },
        onDone: () {
          if (generation != _generation) return;
          if (state.phase != JamPhase.error) {
            state = const JamSnapshot();
          }
        },
        cancelOnError: true,
      );
      onOpen();
    } catch (error) {
      if (generation != _generation) return;
      state = JamSnapshot(
        phase: JamPhase.error,
        error: error.toString(),
      );
    }
  }

  void _onMessage(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final type = decoded['type']?.toString() ?? '';
      final payload = decoded['payload'];
      final map = payload is Map
          ? payload.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{};
      switch (type) {
        case 'room_created':
          final userId = map['user_id']?.toString() ?? '';
          final name = (map['name']?.toString() ?? '').isEmpty
              ? 'Host'
              : map['name'].toString();
          state = JamSnapshot(
            phase: JamPhase.active,
            roomCode: map['room_code']?.toString() ?? '',
            userId: userId,
            displayName: name,
            isHost: true,
            hostId: userId,
            roomMode: map['room_mode']?.toString() ?? jamModeCollaborative,
            people: [JamPerson(userId: userId, name: name, isHost: true)],
          );
        case 'sync_state':
          final playback = map['playback'] is Map
              ? (map['playback'] as Map)
                  .map((k, v) => MapEntry(k.toString(), v))
              : const <String, dynamic>{};
          final trackRaw = playback['current_track'];
          final track = trackRaw is Map
              ? JamTrack.fromJson(
                  trackRaw.map((k, v) => MapEntry(k.toString(), v)),
                )
              : null;
          final people = _people(map['participants']);
          final chat = _chat(map['chat_history']);
          state = JamSnapshot(
            phase: JamPhase.active,
            roomCode: map['room_code']?.toString() ?? '',
            userId: map['user_id']?.toString() ?? '',
            displayName: map['name']?.toString() ?? '',
            isHost: map['is_host'] == true,
            hostId: map['host_id']?.toString() ?? '',
            coHostId: map['cohost_id']?.toString() ?? '',
            permanent: map['permanent'] == true,
            radio: map['radio'] == true,
            stationAuto: map['station_auto'] != false,
            roomName: map['room_name']?.toString() ?? '',
            roomMode: map['room_mode']?.toString() ?? jamModeCollaborative,
            people: people,
            chat: chat,
            track: track,
            isPlaying: playback['is_playing'] == true,
            queue: _tracks(playback['queue']),
          );
          _remote.add(JamRemoteFull(
            track: track,
            isPlaying: playback['is_playing'] == true,
            positionMs: _int(playback['position_ms']),
            serverTimeMs: _int(playback['server_time_ms']),
          ));
        case 'user_joined':
          if (state.phase != JamPhase.active) return;
          final person = JamPerson(
            userId: map['user_id']?.toString() ?? '',
            name: map['name']?.toString() ?? '',
            isHost: map['is_host'] == true,
          );
          final next = [
            ...state.people.where((p) => p.userId != person.userId),
            person,
          ];
          state = state.copyWith(people: next);
        case 'user_left':
          if (state.phase != JamPhase.active) return;
          final id = map['user_id']?.toString() ?? '';
          state = state.copyWith(
            people: state.people.where((p) => p.userId != id).toList(),
          );
        case 'host_changed':
          if (state.phase != JamPhase.active) return;
          final hostId = (map['host_id']?.toString() ?? '').isNotEmpty
              ? map['host_id'].toString()
              : (map['new_host_id']?.toString() ?? '').isNotEmpty
                  ? map['new_host_id'].toString()
                  : (map['user_id']?.toString() ?? '');
          _applyRoles(hostId, map['cohost_id']?.toString() ?? '');
        case 'station_mode':
          if (state.phase != JamPhase.active) return;
          state = state.copyWith(stationAuto: map['auto'] == true);
        case 'cooldown':
          _startCooldown(_int(map['retry_at_ms']));
        case 'queue_updated':
          if (state.phase != JamPhase.active) return;
          state = state.copyWith(queue: _tracks(map['queue']));
        case 'cohost_changed':
          if (state.phase != JamPhase.active) return;
          _applyRoles(
            map['host_id']?.toString() ?? state.hostId,
            map['cohost_id']?.toString() ?? '',
          );
        case 'room_mode_changed':
          state = state.copyWith(
            roomMode: map['room_mode']?.toString() ?? state.roomMode,
          );
        case 'chat_message':
          final next = [...state.chat, _chatLine(map)];
          state = state.copyWith(
            chat: next.length > 50 ? next.sublist(next.length - 50) : next,
          );
        case 'sync_playback':
          _applyPlayback(map);
        case 'error':
          // A rejected request inside a room must not eject you from it;
          // show it as a notice instead.
          if (state.phase == JamPhase.active) {
            final message = map['message']?.toString() ?? '';
            if (map['code'] == 'rate_limited') {
              final retryAt = _int(map['retry_at_ms']);
              final after = _int(map['retry_after_ms']);
              final until = retryAt > 0
                  ? retryAt
                  : DateTime.now().millisecondsSinceEpoch + after;
              state = state.copyWith(notice: message, retryAtMs: until);
              _startCooldown(until);
            } else if (message.isNotEmpty) {
              state = state.copyWith(notice: message, retryAtMs: 0);
            }
            return;
          }
          state = state.copyWith(
            phase: JamPhase.error,
            error: (map['message']?.toString() ?? '').isEmpty
                ? 'Unknown server error'
                : map['message'].toString(),
          );
        case 'pong':
          break;
      }
    } catch (_) {}
  }

  void _applyRoles(String hostId, String coHostId) {
    state = state.copyWith(
      hostId: hostId,
      coHostId: coHostId,
      isHost: state.userId == hostId || state.userId == coHostId,
      people: [
        for (final person in state.people)
          JamPerson(
            userId: person.userId,
            name: person.name,
            isHost: person.userId == hostId || person.userId == coHostId,
            isCoHost: coHostId.isNotEmpty && person.userId == coHostId,
          ),
      ],
    );
  }

  JamChatLine _chatLine(Map item) {
    final reply = item['reply_to'];
    return JamChatLine(
      id: item['id']?.toString() ?? '',
      userId: item['user_id']?.toString() ?? '',
      userName: item['user_name']?.toString() ?? '',
      isHost: item['is_host'] == true,
      text: item['text']?.toString() ?? '',
      timestamp: _int(item['timestamp']),
      replyTo: reply is Map
          ? JamReply(
              id: reply['id']?.toString() ?? '',
              userName: reply['user_name']?.toString() ?? '',
              text: reply['text']?.toString() ?? '',
            )
          : null,
    );
  }

  void _applyPlayback(Map<String, dynamic> action) {
    final trackRaw = action['track'];
    final track = trackRaw is Map
        ? JamTrack.fromJson(trackRaw.map((k, v) => MapEntry(k.toString(), v)))
        : state.track;
    final playing = action['is_playing'] == true;
    state = state.copyWith(
      isPlaying: playing,
      track: track,
    );
    final from = action['from_user_id']?.toString();
    final position = _int(action['position_ms']);
    switch (action['action']?.toString()) {
      case 'play':
        _remote.add(JamRemotePlay(
          position,
          _int(action['server_time_ms']),
          from,
        ));
      case 'pause':
        _remote.add(JamRemotePause(position, from));
      case 'seek':
        _remote.add(JamRemoteSeek(position, from));
      case 'change_track':
        if (track != null && track.id.isNotEmpty) {
          _remote.add(JamRemoteTrack(track, playing, position, from));
        }
    }
  }

  List<JamPerson> _people(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          JamPerson(
            userId: item['user_id']?.toString() ?? '',
            name: item['name']?.toString() ?? '',
            isHost: item['is_host'] == true,
            isCoHost: item['is_cohost'] == true,
          ),
    ];
  }

  List<JamChatLine> _chat(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) _chatLine(item),
    ];
  }

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  void _send(String type, Map<String, dynamic>? payload) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode({'type': type, 'payload': payload}));
    } catch (_) {}
  }

  Future<void> _close({required bool clear}) async {
    _ping?.cancel();
    _ping = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(1000, 'Normal closure');
      } catch (_) {}
    }
    if (clear) state = const JamSnapshot();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _generation++;
    _ping?.cancel();
    _socket?.close();
    _remote.close();
    super.dispose();
  }
}

final jamControllerProvider =
    StateNotifierProvider<JamController, JamSnapshot>((ref) {
  return JamController(ref);
});
