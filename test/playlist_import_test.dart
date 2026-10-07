import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/library/playlist_import.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';

YouTubeMusicTrack _track(String id, String title, String artist) =>
    YouTubeMusicTrack(
        videoId: id, title: title, artist: artist, artworkUrl: 'art-$id');

class _FakeSource implements PlaylistTrackSource {
  YouTubePlaylistResult? playlist;
  final Map<String, YouTubeMusicTrack?> matches = {};
  bool findMatchCalled = false;

  @override
  Future<YouTubePlaylistResult?> fetchPlaylist(String idOrUrl) async =>
      playlist;

  @override
  Future<YouTubeMusicTrack?> findMatch(String title, String artist) async {
    findMatchCalled = true;
    return matches['$title|$artist'];
  }
}

class _FakeWriter implements PlaylistWriter {
  String? createdTitle;
  final added = <StoredTrack>[];

  @override
  Future<SavedPlaylist> createCustom(String title) async {
    createdTitle = title;
    return SavedPlaylist(id: 7, title: title);
  }

  @override
  Future<bool> addTrack(int id, StoredTrack track) async {
    added.add(track);
    return true;
  }
}

Dio _pageDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
          if (url.contains('spotify.com/embed')) {
            handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data:
                    '<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"uri":"spotify:playlist:P1","title":"Spot Mix","trackList":[{"uri":"spotify:track:T1","title":"Hit One","subtitle":"Star A"},{"uri":"spotify:track:T2","title":"Hit Two","subtitle":"Star B"},{"uri":"spotify:track:T3","title":"Lost Song","subtitle":"Nobody"}]}}}}}}</script>'));
            return;
          }
        handler.reject(DioException(
            requestOptions: options, type: DioExceptionType.unknown));
      },
    ),
  );
  return dio;
}

void main() {
  test('YouTube link imports direct tracks without matching', () async {
    final source = _FakeSource()
      ..playlist = YouTubePlaylistResult(
        id: 'PLxyz',
        title: 'YT Mix',
        tracks: [_track('v1', 'Song One', 'Singer A')],
      );
    final preview = await previewPlaylistLinkWith(
      source,
      _pageDio(),
      'https://music.youtube.com/playlist?list=PLxyz',
    );
    expect(preview.title, 'YT Mix');
    expect(preview.totalRows, 1);
    expect(preview.matchedTracks.single.videoId, 'v1');
    expect(source.findMatchCalled, isFalse);
  });

  test('Spotify rows match with misses dropped and counted', () async {
    final source = _FakeSource();
    source.matches['Hit One|Star A'] = _track('v1', 'Hit One', 'Star A');
    source.matches['Hit Two|Star B'] = _track('v2', 'Hit Two', 'Star B');
    final preview = await previewPlaylistLinkWith(
      source,
      _pageDio(),
      'https://open.spotify.com/playlist/P1',
    );
    expect(preview.title, 'Spot Mix');
    expect(preview.totalRows, 3);
    expect(preview.matchedTracks.length, 2);
    expect(
      preview.matchedTracks.map((t) => t.videoId).toList(),
      ['v1', 'v2'],
    );
  });

  test('garbage, mixes and empty results fail loudly', () async {
    final source = _FakeSource();
    await expectLater(
      previewPlaylistLinkWith(source, _pageDio(), 'hello world'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      previewPlaylistLinkWith(
          source, _pageDio(), 'https://music.youtube.com/playlist?list=RDxyz'),
      throwsA(isA<FormatException>()),
    );
    source.playlist = const YouTubePlaylistResult(id: 'PLempty', title: 'E');
    await expectLater(
      previewPlaylistLinkWith(
          source, _pageDio(), 'https://music.youtube.com/playlist?list=PLempty'),
      throwsA(isA<StateError>()),
    );
  });

  test('importPreview creates playlist with matched tracks only', () async {
    final writer = _FakeWriter();
    final created = await importPreviewWith(
      writer,
      PlaylistImportPreview(
        title: 'Spot Mix',
        totalRows: 3,
        matchedTracks: const [
          StoredTrack(name: 'Hit One', artist: 'Star A', videoId: 'v1'),
          StoredTrack(name: 'Hit Two', artist: 'Star B', videoId: 'v2'),
        ],
      ),
    );
    expect(created.id, 7);
    expect(writer.createdTitle, 'Spot Mix');
    expect(writer.added.map((t) => t.videoId).toList(), ['v1', 'v2']);
  });
}
