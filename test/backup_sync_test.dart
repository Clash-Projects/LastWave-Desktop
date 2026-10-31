import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/backup/backup_sync.dart';

Map<String, dynamic> t(String name, [String url = '']) => {
  'name': name,
  'artist': 'A',
  'url': url,
};

Map<String, dynamic> pl(
  int id,
  List<Map<String, dynamic>> tracks, {
  String title = 'P',
  String mode = 'custom',
  bool pinned = false,
}) => {
  'id': id,
  'title': title,
  'subtitle': '',
  'mode': mode,
  'tracksJson': jsonEncode(tracks),
  'createdAtMillis': id,
  'isPinned': pinned,
};

Map<String, dynamic> ex(String key) => {'trackKey': key};

MergedLibrary merge({
  List<Map<String, dynamic>>? base,
  required List<Map<String, dynamic>> local,
  required List<Map<String, dynamic>> remote,
  List<Map<String, dynamic>>? baseEx,
  List<Map<String, dynamic>> localEx = const [],
  List<Map<String, dynamic>> remoteEx = const [],
  bool Function(Map<String, dynamic>)? holds,
}) => mergeLibraries(
  basePlaylists: base,
  baseExclusions: baseEx ?? (base == null ? null : const []),
  localPlaylists: local,
  localExclusions: localEx,
  remotePlaylists: remote,
  remoteExclusions: remoteEx,
  holds: holds,
);

List<String> names(Map<String, dynamic> playlist) => [
  for (final x in tracksOf(playlist)) x['name'] as String,
];

void main() {
  test('first sync keeps everything: file order, then local additions', () {
    final m = merge(
      local: [
        pl(1, [t('a'), t('c')]),
        pl(2, [t('x')]),
      ],
      remote: [
        pl(1, [t('a'), t('b')]),
        pl(3, [t('y')]),
      ],
    );
    expect(m.playlists.map((p) => p['id']), [1, 3, 2]);
    expect(names(m.playlists.first), ['a', 'b', 'c']);
  });

  test('a track removed here and one added there both apply', () {
    final base = [
      pl(1, [t('a'), t('b')]),
    ];
    final m = merge(
      base: base,
      local: [
        pl(1, [t('a')]),
      ],
      remote: [
        pl(1, [t('a'), t('b'), t('c')]),
      ],
    );
    expect(names(m.playlists.single), ['a', 'c']);
  });

  test('a track removed there stays removed even though it is still here', () {
    final m = merge(
      base: [
        pl(1, [t('a'), t('b')]),
      ],
      local: [
        pl(1, [t('a'), t('b')]),
      ],
      remote: [
        pl(1, [t('a')]),
      ],
    );
    expect(names(m.playlists.single), ['a']);
  });

  test('deleted playlists go, unless the other side edited them', () {
    final base = [
      pl(1, [t('a')]),
      pl(2, [t('b')]),
    ];
    final m = merge(
      base: base,
      // 1 deleted here; 2 deleted there but edited here.
      local: [
        pl(2, [t('b'), t('c')]),
      ],
      remote: [
        pl(1, [t('a')]),
      ],
    );
    expect(m.playlists.map((p) => p['id']), [2]);

    final edited = merge(
      base: base,
      local: [
        pl(2, [t('b')]),
      ],
      remote: [
        pl(1, [t('a'), t('z')]),
        pl(2, [t('b')]),
      ],
    );
    expect(edited.playlists.map((p) => p['id']), [1, 2]);
  });

  test('renames: ours wins when we changed it, theirs otherwise', () {
    final base = [pl(1, [], title: 'Old'), pl(2, [], title: 'Old')];
    final m = merge(
      base: base,
      local: [
        pl(1, [], title: 'Mine'),
        pl(2, [], title: 'Old', pinned: true),
      ],
      remote: [
        pl(1, [], title: 'Theirs'),
        pl(2, [], title: 'Theirs'),
      ],
    );
    expect(m.playlists[0]['title'], 'Mine');
    expect(m.playlists[1]['title'], 'Theirs');
    expect(m.playlists[1]['isPinned'], isTrue);
  });

  test('Liked Songs match by mode whatever their ids', () {
    final m = merge(
      local: [
        pl(10, [t('a')], mode: 'liked'),
      ],
      remote: [
        pl(20, [t('b')], mode: 'liked'),
      ],
    );
    expect(m.playlists, hasLength(1));
    expect(m.playlists.single['id'], 20);
    expect(names(m.playlists.single), ['b', 'a']);
  });

  test('tracks this device cannot hold are never read as deleted', () {
    bool holds(Map<String, dynamic> x) => !(x['url'] as String).startsWith('/');
    final phoneSong = t('mine', '/storage/emulated/0/Music/mine.flac');
    final m = merge(
      base: [
        pl(1, [t('a'), phoneSong]),
      ],
      local: [
        pl(1, [t('a'), t('b')]),
      ],
      remote: [
        pl(1, [t('a'), phoneSong]),
      ],
      holds: holds,
    );
    expect(names(m.playlists.single), ['a', 'mine', 'b']);

    // Deleting the playlist here is still a delete, even with phone songs.
    final gone = merge(
      base: [
        pl(1, [t('a'), phoneSong]),
      ],
      local: const [],
      remote: [
        pl(1, [t('a'), phoneSong]),
      ],
      holds: holds,
    );
    expect(gone.playlists, isEmpty);
  });

  test('exclusions merge the same way', () {
    final m = merge(
      base: const [],
      local: const [],
      remote: const [],
      baseEx: [ex('a|x'), ex('b|x')],
      localEx: [ex('b|x'), ex('c|x')],
      remoteEx: [ex('a|x'), ex('b|x'), ex('d|x')],
    );
    expect(m.exclusions.map((e) => e['trackKey']), ['b|x', 'd|x', 'c|x']);
  });
}
