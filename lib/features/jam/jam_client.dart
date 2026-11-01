import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

const jamDefaultServer = 'wss://jam.clashprojects.qd.je/ws';

const jamModeCollaborative = 'collaborative';
const jamModeHostOnly = 'host_only';

class JamPerson {
  final String userId;
  final String name;
  final bool isHost;
  const JamPerson({
    required this.userId,
    required this.name,
    this.isHost = false,
  });
}

class JamChatLine {
  final String id;
  final String userId;
  final String userName;
  final bool isHost;
  final String text;
  final int timestamp;
  const JamChatLine({
    required this.id,
    required this.userId,
    required this.userName,
    required this.text,
    this.isHost = false,
    this.timestamp = 0,
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
  final String roomMode;
  final List<JamPerson> people;
  final List<JamChatLine> chat;
  final JamTrack? track;
  final bool isPlaying;

  const JamSnapshot({
    this.phase = JamPhase.disconnected,
    this.error = '',
    this.roomCode = '',
    this.userId = '',
    this.displayName = '',
    this.isHost = false,
    this.roomMode = jamModeCollaborative,
    this.people = const [],
    this.chat = const [],
    this.track,
    this.isPlaying = false,
  });

  JamSnapshot copyWith({
    JamPhase? phase,
    String? error,
    String? roomCode,
    String? userId,
    String? displayName,
    bool? isHost,
    String? roomMode,
    List<JamPerson>? people,
    List<JamChatLine>? chat,
    JamTrack? track,
    bool clearTrack = false,
    bool? isPlaying,
  }) =>
      JamSnapshot(
        phase: phase ?? this.phase,
        error: error ?? this.error,
        roomCode: roomCode ?? this.roomCode,
        userId: userId ?? this.userId,
        displayName: displayName ?? this.displayName,
        isHost: isHost ?? this.isHost,
        roomMode: roomMode ?? this.roomMode,
        people: people ?? this.people,
        chat: chat ?? this.chat,
        track: clearTrack ? null : (track ?? this.track),
        isPlaying: isPlaying ?? this.isPlaying,
      );
}

/// WebSocket client for the Clash Projects Jam server.
///
/// A failed connection sets [JamPhase.error] and does not touch playback.
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
    final code = roomCode.trim().toUpperCase();
    final name = displayName.trim().isEmpty ? 'Listener' : displayName.trim();
    if (code.isEmpty) {
      state = state.copyWith(
        phase: JamPhase.error,
        error: 'Room code is required',
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

  void sendChat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _send('send_chat', {'text': trimmed});
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
            roomMode: map['room_mode']?.toString() ?? jamModeCollaborative,
            people: people,
            chat: chat,
            track: track,
            isPlaying: playback['is_playing'] == true,
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
          final hostId = (map['new_host_id']?.toString() ?? '').isNotEmpty
              ? map['new_host_id'].toString()
              : (map['user_id']?.toString() ?? '');
          state = state.copyWith(
            isHost: hostId == state.userId,
            people: [
              for (final person in state.people)
                JamPerson(
                  userId: person.userId,
                  name: person.name,
                  isHost: person.userId == hostId,
                ),
            ],
          );
        case 'room_mode_changed':
          state = state.copyWith(
            roomMode: map['room_mode']?.toString() ?? state.roomMode,
          );
        case 'chat_message':
          final line = JamChatLine(
            id: map['id']?.toString() ?? '',
            userId: map['user_id']?.toString() ?? '',
            userName: map['user_name']?.toString() ?? '',
            isHost: map['is_host'] == true,
            text: map['text']?.toString() ?? '',
            timestamp: _int(map['timestamp']),
          );
          final next = [...state.chat, line];
          state = state.copyWith(
            chat: next.length > 50 ? next.sublist(next.length - 50) : next,
          );
        case 'sync_playback':
          _applyPlayback(map);
        case 'error':
          // A rejected request inside a room must not eject you from it.
          if (state.phase == JamPhase.active) return;
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
          ),
    ];
  }

  List<JamChatLine> _chat(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          JamChatLine(
            id: item['id']?.toString() ?? '',
            userId: item['user_id']?.toString() ?? '',
            userName: item['user_name']?.toString() ?? '',
            isHost: item['is_host'] == true,
            text: item['text']?.toString() ?? '',
            timestamp: _int(item['timestamp']),
          ),
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
