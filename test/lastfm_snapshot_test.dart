import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lastfm/home_repository.dart';
import 'package:lastwave_desktop/features/lastfm/lastfm_snapshot.dart';

void main() {
  test('keys are scoped to the account and the viewed profile', () {
    expect(lastFmCacheKey('stats', ''), isNull);
    expect(lastFmCacheKey('stats', 'Me'), 'lf_stats_v1|me|me');
    expect(lastFmCacheKey('stats', 'Me', viewing: 'Pal'), 'lf_stats_v1|me|pal');
    expect(lastFmCacheKey('top', 'me', extra: '7day'), 'lf_top_v1|me|me|7day');
    expect(lastFmCacheKey('stats', 'a') == lastFmCacheKey('stats', 'b'), isFalse);
  });

  test('tracks round-trip', () {
    final c = homeTracksSnapshotCodec;
    final back = c.decode(c.encode(const [
      HomeTrack(name: 'N', artist: 'A', artworkUrl: 'u', timestampMillis: 5, playCount: 3),
      HomeTrack(name: 'M', artist: 'B'),
    ]))!;
    expect(back.length, 2);
    expect(back[0].timestampMillis, 5);
    expect(back[0].playCount, 3);
    expect(back[1].timestampMillis, isNull);
    expect(c.decode('nope'), isNull);
  });

  test('friends and stats round-trip; zero stats count as empty', () {
    final f = friendEntriesSnapshotCodec;
    final fb = f.decode(f.encode(const [FriendEntry(name: 'x', realName: 'X', avatarUrl: 'a')]))!;
    expect(fb.single.realName, 'X');
    final s = homeStatsSnapshotCodec;
    final sb = s.decode(s.encode(const HomeStats(scrobbles: 9, artistCount: 2, albumCount: 3, trackCount: 4, avatarUrl: 'z')))!;
    expect((sb.scrobbles, sb.artistCount, sb.albumCount, sb.trackCount, sb.avatarUrl), (9, 2, 3, 4, 'z'));
    expect(s.isEmpty(const HomeStats()), isTrue);
    expect(s.isEmpty(sb), isFalse);
  });
}
