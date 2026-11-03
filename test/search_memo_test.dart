import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/lastfm_api.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/search/search_repository.dart';

class _FakeTube extends Fake implements InnerTubeMusicApi {
  int calls = 0;
  bool fail = false;
  List<YouTubeMusicTrack> result = const [
    YouTubeMusicTrack(videoId: 'v', title: 'Song', artist: 'Artist'),
  ];

  @override
  Future<List<YouTubeMusicTrack>> searchSongs(String query,
      {int limit = 30, bool prefetchStreams = false}) async {
    calls++;
    if (fail) throw Exception('offline');
    return result;
  }
}

class _FakeApi extends Fake implements LastFmApiService {}

class _FakeDb extends Fake implements AppDatabase {}

void main() {
  late _FakeTube tube;
  late DateTime now;
  late SearchRepository repo;

  setUp(() {
    tube = _FakeTube();
    now = DateTime(2026, 11, 4, 12);
    repo = SearchRepository(_FakeApi(), tube, _FakeDb(), () => '',
        clock: () => now);
  });

  test('a repeat query is served from the memo, case and spacing aside',
      () async {
    await repo.search(SearchTab.tracks, 'Hello');
    await repo.search(SearchTab.tracks, '  hello ');
    expect(tube.calls, 1);
  });

  test('different tabs and queries do not share an entry', () async {
    await repo.search(SearchTab.tracks, 'a');
    await repo.search(SearchTab.tracks, 'b');
    expect(tube.calls, 2);
  });

  test('concurrent callers share one request', () async {
    await Future.wait([
      repo.search(SearchTab.tracks, 'x'),
      repo.search(SearchTab.tracks, 'x'),
    ]);
    expect(tube.calls, 1);
  });

  test('entries expire after ten minutes', () async {
    await repo.search(SearchTab.tracks, 'x');
    now = now.add(const Duration(minutes: 11));
    await repo.search(SearchTab.tracks, 'x');
    expect(tube.calls, 2);
  });

  test('a failure is not remembered', () async {
    tube.fail = true;
    await expectLater(repo.search(SearchTab.tracks, 'x'), throwsException);
    tube.fail = false;
    await repo.search(SearchTab.tracks, 'x');
    expect(tube.calls, 2);
  });

  test('an empty answer is not remembered', () async {
    tube.result = const [];
    await repo.search(SearchTab.tracks, 'x');
    await Future<void>.delayed(Duration.zero);
    tube.result = const [
      YouTubeMusicTrack(videoId: 'v', title: 'Song', artist: 'Artist'),
    ];
    final again = await repo.search(SearchTab.tracks, 'x');
    expect(tube.calls, 2);
    expect(again, isNotEmpty);
  });
}
