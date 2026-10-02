import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/audio/stream_models.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';

const _busName = 'org.mpris.MediaPlayer2.lastwave';
const _rootIface = 'org.mpris.MediaPlayer2';
const _playerIface = 'org.mpris.MediaPlayer2.Player';

/// MPRIS (org.mpris.MediaPlayer2) endpoint for Linux desktops.
///
/// Exposes the current track and transport controls on the session bus so
/// status bars, `playerctl`, media keys and lock screens can see and drive
/// LastWave. State is pushed from [PlayerSnapshot] changes; commands call
/// straight back into [PlaybackService]. Linux only; every failure (no
/// session bus, name already taken) degrades to silence.
class MprisService {
  final Ref _ref;
  DBusClient? _client;
  _MprisObject? _object;
  bool _disposed = false;

  MprisService(this._ref);

  PlaybackService get _player => _ref.read(playbackServiceProvider.notifier);

  Future<void> startup() async {
    if (!Platform.isLinux || _client != null || _disposed) return;
    try {
      final client = DBusClient.session();
      final object = _MprisObject(this);
      await client.registerObject(object);
      await client.requestName(_busName,
          flags: {DBusRequestNameFlag.doNotQueue});
      _client = client;
      _object = object;
      object.apply(_ref.read(playbackServiceProvider));
    } catch (_) {
      await shutdown();
    }
  }

  void onSnapshot(PlayerSnapshot snap) => _object?.apply(snap);

  Future<void> shutdown() async {
    final client = _client;
    _client = null;
    _object = null;
    try {
      await client?.close();
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    unawaited(shutdown());
  }
}

class _MprisObject extends DBusObject {
  final MprisService _svc;
  PlayerSnapshot _snap = const PlayerSnapshot();
  String _trackId = '/org/mpris/MediaPlayer2/TrackList/NoTrack';
  String _trackKey = '';
  int _trackSeq = 0;

  _MprisObject(this._svc) : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  // ---- state -> properties
  String get _status => _snap.current == null
      ? 'Stopped'
      : (_snap.isPlaying ? 'Playing' : 'Paused');

  String get _loop => switch (_snap.repeatMode) {
        RepeatMode.off => 'None',
        RepeatMode.all => 'Playlist',
        RepeatMode.one => 'Track',
      };

  DBusValue get _metadata {
    final t = _snap.current;
    if (t == null) {
      return DBusDict.stringVariant({
        'mpris:trackid':
            DBusObjectPath('/org/mpris/MediaPlayer2/TrackList/NoTrack'),
      });
    }
    return DBusDict.stringVariant({
      'mpris:trackid': DBusObjectPath(_trackId),
      if (_snap.duration > Duration.zero)
        'mpris:length': DBusInt64(_snap.duration.inMicroseconds),
      if (t.artworkUrl.isNotEmpty) 'mpris:artUrl': DBusString(t.artworkUrl),
      'xesam:title': DBusString(t.title),
      'xesam:artist': DBusArray.string(
          t.artist.isEmpty ? const <String>[] : [t.artist]),
      if (t.album.isNotEmpty) 'xesam:album': DBusString(t.album),
    });
  }

  Map<String, DBusValue> get _playerProps => {
        'PlaybackStatus': DBusString(_status),
        'LoopStatus': DBusString(_loop),
        'Rate': DBusDouble(_snap.speed),
        'Shuffle': DBusBoolean(_snap.shuffleEnabled),
        'Metadata': _metadata,
        'Volume': DBusDouble(_snap.volume),
        'Position': DBusInt64(_snap.position.inMicroseconds),
        'MinimumRate': DBusDouble(0.25),
        'MaximumRate': DBusDouble(4.0),
        'CanGoNext': DBusBoolean(_snap.current != null),
        'CanGoPrevious': DBusBoolean(_snap.current != null),
        'CanPlay': DBusBoolean(_snap.current != null),
        'CanPause': DBusBoolean(_snap.current != null),
        'CanSeek': DBusBoolean(
            _snap.current != null && _snap.duration > Duration.zero),
        'CanControl': DBusBoolean(true),
      };

  static final Map<String, DBusValue> _rootProps = {
    'CanQuit': DBusBoolean(false),
    'CanRaise': DBusBoolean(true),
    'HasTrackList': DBusBoolean(false),
    'Identity': DBusString('LastWave'),
    'DesktopEntry': DBusString('lastwave'),
    'SupportedUriSchemes': DBusArray.string(const <String>[]),
    'SupportedMimeTypes': DBusArray.string(const <String>[]),
  };

  /// Applies a new snapshot and emits only what changed. Position is not
  /// signalled per tick (MPRIS clients extrapolate); a jump emits Seeked.
  void apply(PlayerSnapshot next) {
    final prev = _snap;
    final key = next.current?.mediaId ?? '';
    if (key != _trackKey) {
      _trackKey = key;
      _trackId = key.isEmpty
          ? '/org/mpris/MediaPlayer2/TrackList/NoTrack'
          : '/org/lastwave/track/${++_trackSeq}';
    }
    _snap = next;

    final changed = <String, DBusValue>{};
    final p = _playerProps;
    if (prev.current?.mediaId != next.current?.mediaId ||
        prev.duration != next.duration ||
        prev.current?.artworkUrl != next.current?.artworkUrl) {
      changed['Metadata'] = p['Metadata']!;
      changed['CanGoNext'] = p['CanGoNext']!;
      changed['CanGoPrevious'] = p['CanGoPrevious']!;
      changed['CanPlay'] = p['CanPlay']!;
      changed['CanPause'] = p['CanPause']!;
      changed['CanSeek'] = p['CanSeek']!;
    }
    if (prev.isPlaying != next.isPlaying ||
        (prev.current == null) != (next.current == null)) {
      changed['PlaybackStatus'] = p['PlaybackStatus']!;
    }
    if (prev.repeatMode != next.repeatMode) {
      changed['LoopStatus'] = p['LoopStatus']!;
    }
    if (prev.shuffleEnabled != next.shuffleEnabled) {
      changed['Shuffle'] = p['Shuffle']!;
    }
    if (prev.speed != next.speed) changed['Rate'] = p['Rate']!;
    if ((prev.volume - next.volume).abs() > 0.001) {
      changed['Volume'] = p['Volume']!;
    }
    if (changed.isNotEmpty) {
      changed['Position'] = p['Position']!;
      unawaited(emitPropertiesChanged(_playerIface, changedProperties: changed)
          .catchError((_) {}));
    }

    // Detect user seeks: position moved more than playback time explains.
    final delta = (next.position - prev.position).abs();
    if (prev.current?.mediaId == next.current?.mediaId &&
        delta > const Duration(seconds: 3) &&
        prev.isPlaying == next.isPlaying) {
      unawaited(emitSignal(_playerIface, 'Seeked',
              [DBusInt64(next.position.inMicroseconds)])
          .catchError((_) {}));
    }
  }

  // ---- introspection
  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(_rootIface, methods: [
          DBusIntrospectMethod('Raise'),
          DBusIntrospectMethod('Quit'),
        ], properties: [
          for (final e in {
            'CanQuit': 'b',
            'CanRaise': 'b',
            'HasTrackList': 'b',
            'Identity': 's',
            'DesktopEntry': 's',
            'SupportedUriSchemes': 'as',
            'SupportedMimeTypes': 'as',
          }.entries)
            DBusIntrospectProperty(e.key, DBusSignature(e.value),
                access: DBusPropertyAccess.read),
        ]),
        DBusIntrospectInterface(_playerIface, methods: [
          DBusIntrospectMethod('Next'),
          DBusIntrospectMethod('Previous'),
          DBusIntrospectMethod('Pause'),
          DBusIntrospectMethod('PlayPause'),
          DBusIntrospectMethod('Stop'),
          DBusIntrospectMethod('Play'),
          DBusIntrospectMethod('Seek', args: [
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.in_,
                name: 'Offset')
          ]),
          DBusIntrospectMethod('SetPosition', args: [
            DBusIntrospectArgument(
                DBusSignature('o'), DBusArgumentDirection.in_,
                name: 'TrackId'),
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.in_,
                name: 'Position'),
          ]),
          DBusIntrospectMethod('OpenUri', args: [
            DBusIntrospectArgument(
                DBusSignature('s'), DBusArgumentDirection.in_,
                name: 'Uri')
          ]),
        ], signals: [
          DBusIntrospectSignal('Seeked', args: [
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.out,
                name: 'Position')
          ]),
        ], properties: [
          DBusIntrospectProperty('PlaybackStatus', DBusSignature('s'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('LoopStatus', DBusSignature('s'),
              access: DBusPropertyAccess.readwrite),
          DBusIntrospectProperty('Rate', DBusSignature('d'),
              access: DBusPropertyAccess.readwrite),
          DBusIntrospectProperty('Shuffle', DBusSignature('b'),
              access: DBusPropertyAccess.readwrite),
          DBusIntrospectProperty('Metadata', DBusSignature('a{sv}'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('Volume', DBusSignature('d'),
              access: DBusPropertyAccess.readwrite),
          DBusIntrospectProperty('Position', DBusSignature('x'),
              access: DBusPropertyAccess.read),
          for (final n in [
            'MinimumRate',
            'MaximumRate',
          ])
            DBusIntrospectProperty(n, DBusSignature('d'),
                access: DBusPropertyAccess.read),
          for (final n in [
            'CanGoNext',
            'CanGoPrevious',
            'CanPlay',
            'CanPause',
            'CanSeek',
            'CanControl',
          ])
            DBusIntrospectProperty(n, DBusSignature('b'),
                access: DBusPropertyAccess.read),
        ]),
      ];

  // ---- properties
  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final props = switch (interface) {
      _rootIface => _rootProps,
      _playerIface => _playerProps,
      _ => null,
    };
    final v = props?[name];
    if (v == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(v);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    return DBusGetAllPropertiesResponse(switch (interface) {
      _rootIface => _rootProps,
      _playerIface => _playerProps,
      _ => <String, DBusValue>{},
    });
  }

  @override
  Future<DBusMethodResponse> setProperty(
      String interface, String name, DBusValue value) async {
    if (interface != _playerIface) {
      return DBusMethodErrorResponse.propertyReadOnly();
    }
    final player = _svc._player;
    switch (name) {
      case 'Volume':
        await player.setVolume((value as DBusDouble).value.clamp(0.0, 1.0));
      case 'Shuffle':
        if ((value as DBusBoolean).value != _snap.shuffleEnabled) {
          await player.toggleShuffle();
        }
      case 'LoopStatus':
        final want = (value as DBusString).value;
        for (var i = 0; i < 3 && _loop != want; i++) {
          await player.cycleRepeat();
        }
      case 'Rate':
        await player.setSpeed((value as DBusDouble).value);
      default:
        return DBusMethodErrorResponse.propertyReadOnly();
    }
    return DBusMethodSuccessResponse();
  }

  // ---- methods
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    final player = _svc._player;
    try {
      if (call.interface == _rootIface) {
        switch (call.name) {
          case 'Raise':
            await windowManager.show();
            await windowManager.focus();
            return DBusMethodSuccessResponse();
          case 'Quit':
            return DBusMethodSuccessResponse();
        }
      } else if (call.interface == _playerIface) {
        switch (call.name) {
          case 'Next':
            await player.next();
          case 'Previous':
            await player.previous();
          case 'Pause':
            await player.pause();
          case 'Play':
            if (!_snap.isPlaying) await player.toggle();
          case 'PlayPause':
            await player.toggle();
          case 'Stop':
            await player.pause();
          case 'Seek':
            final off = Duration(microseconds: call.values[0].asInt64());
            final target = _snap.position + off;
            await player.seek(target < Duration.zero ? Duration.zero : target);
          case 'SetPosition':
            if (call.values[0].asObjectPath().value == _trackId) {
              await player.seek(
                  Duration(microseconds: call.values[1].asInt64()));
            }
          case 'OpenUri':
            break;
          default:
            return DBusMethodErrorResponse.unknownMethod();
        }
        return DBusMethodSuccessResponse();
      }
    } catch (_) {
      return DBusMethodErrorResponse.failed();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

final mprisProvider = Provider<MprisService>((ref) {
  final svc = MprisService(ref);
  ref.listen<PlayerSnapshot>(
      playbackServiceProvider, (prev, next) => svc.onSnapshot(next));
  ref.onDispose(svc.dispose);
  return svc;
});
