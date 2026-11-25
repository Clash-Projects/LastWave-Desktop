import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../lastfm/auth_repository.dart';
import 'extra_scrobblers.dart';

/// Supported scrobbler backends for read/write features.
enum ScrobblerKind {
  lastfm('lastfm', 'Last.fm'),
  listenbrainz('listenbrainz', 'ListenBrainz'),
  librefm('librefm', 'Libre.fm');

  final String id;
  final String displayName;
  const ScrobblerKind(this.id, this.displayName);

  static ScrobblerKind? fromId(String id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// Active primary scrobbler session (or [ScrobblerSession.none] in guest mode).
class ScrobblerSession {
  final ScrobblerKind? kind;
  final String username;
  final Uri? profileUrl;

  const ScrobblerSession({
    this.kind,
    this.username = '',
    this.profileUrl,
  });

  static const none = ScrobblerSession();

  bool get connected => kind != null && username.isNotEmpty;
  String get displayName => kind?.displayName ?? '';

  /// Cache key prefix scoped by backend + username so switching primary
  /// scrobblers never collides in `snapshot_cache`.
  String get cacheScope =>
      !connected ? '' : (kind == ScrobblerKind.lastfm ? username : '${kind!.id}:$username');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrobblerSession &&
          kind == other.kind &&
          username == other.username;

  @override
  int get hashCode => Object.hash(kind, username);
}

/// All currently connected scrobbler backends in display order.
final connectedScrobblersProvider = Provider<List<ScrobblerKind>>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  ref.watch(extraScrobblersRevisionProvider);

  ListenBrainzScrobbler? lb;
  LibreFmScrobbler? lf;
  try {
    lb = ref.watch(listenBrainzProvider);
    lf = ref.watch(libreFmProvider);
  } on UnimplementedError {
    // Minimal test containers may override authRepositoryProvider without prefsProvider.
  }

  return [
    if (auth.status == AuthStatus.signedIn && auth.username.isNotEmpty)
      ScrobblerKind.lastfm,
    if (lb != null && lb.connected && lb.username.isNotEmpty)
      ScrobblerKind.listenbrainz,
    if (lf != null && lf.connected && lf.username.isNotEmpty)
      ScrobblerKind.librefm,
  ];
});

/// Resolves the active primary scrobbler used for reading History, Stats,
/// Top Artists/Albums, and Home personalization.
///
/// Honors `Prefs.primaryScrobbler` if that backend is connected; otherwise
/// automatically selects the first connected scrobbler, or [ScrobblerSession.none]
/// when running in Guest + YouTube / Local-only mode.
final activeScrobblerSessionProvider = Provider<ScrobblerSession>((ref) {
  final connected = ref.watch(connectedScrobblersProvider);
  if (connected.isEmpty) return ScrobblerSession.none;

  var prefId = '';
  try {
    prefId = ref.watch(prefsProvider.select((p) => p.primaryScrobbler));
  } on UnimplementedError {
    // Minimal test containers may omit prefsProvider.
  }
  final preferred = ScrobblerKind.fromId(prefId);
  final chosen =
      (preferred != null && connected.contains(preferred))
          ? preferred
          : connected.first;

  switch (chosen) {
    case ScrobblerKind.lastfm:
      final auth = ref.watch(authRepositoryProvider);
      return ScrobblerSession(
        kind: ScrobblerKind.lastfm,
        username: auth.username,
        profileUrl: Uri.parse(
          'https://www.last.fm/user/${Uri.encodeComponent(auth.username)}',
        ),
      );
    case ScrobblerKind.listenbrainz:
      final lb = ref.watch(listenBrainzProvider);
      return ScrobblerSession(
        kind: ScrobblerKind.listenbrainz,
        username: lb.username,
        profileUrl: lb.profileUrl,
      );
    case ScrobblerKind.librefm:
      final lf = ref.watch(libreFmProvider);
      return ScrobblerSession(
        kind: ScrobblerKind.librefm,
        username: lf.username,
        profileUrl: lf.profileUrl,
      );
  }
});
