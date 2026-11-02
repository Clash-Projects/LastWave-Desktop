import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/settings/settings_search.dart';

List<String> titles(String query) => [
      for (final hit in filterSettings(settingsSearchEntries, query)) hit.title,
    ];

void main() {
  test('an empty query finds nothing', () {
    expect(filterSettings(settingsSearchEntries, ''), isEmpty);
    expect(filterSettings(settingsSearchEntries, '   '), isEmpty);
  });

  test('finds a card by a setting inside it', () {
    expect(titles('crossfade'), contains('Playback'));
    expect(titles('amoled'), contains('Surfaces'));
    expect(titles('reorganize'), contains('Offline'));
    expect(titles('export'), contains('Backup'));
  });

  test('every word must match, in any order', () {
    expect(titles('folder layout'), contains('Offline'));
    expect(titles('layout folder'), contains('Offline'));
    expect(titles('crossfade zzzz'), isEmpty);
  });

  test('title matches rank above keyword matches', () {
    // "theme" is Theme's title, but only a keyword of Surfaces.
    expect(titles('theme').first, 'Theme');
  });

  test('is case-insensitive', () {
    expect(titles('LASTFM'), isNotEmpty);
    expect(titles('Equalizer'), contains('Equalizer & Sound FX'));
  });

  test('results are capped', () {
    expect(
      filterSettings(settingsSearchEntries, 'a', limit: 3).length,
      lessThanOrEqualTo(3),
    );
  });

  test('entry ids are unique', () {
    final ids = [for (final e in settingsSearchEntries) e.id];
    expect(ids.toSet().length, ids.length);
  });

  test('the index and the settings page list the same cards', () {
    final source =
        File('lib/ui/settings/settings_page.dart').readAsStringSync();
    final inPage = RegExp(r"^\s+id: '([a-z]+\.[a-z]+)',$", multiLine: true)
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();
    final indexed = {for (final e in settingsSearchEntries) e.id};
    expect(indexed.difference(inPage), isEmpty,
        reason: 'searchable but no card carries this id');
    expect(inPage.difference(indexed), isEmpty,
        reason: 'a card with this id is not searchable');
  });

  test('every entry names a real section', () {
    const sections = {
      'general',
      'playback',
      'audio',
      'downloads',
      'lyrics',
      'appearance',
      'lastfm',
      'integrations',
      'sources',
      'experimental',
      'about',
    };
    for (final e in settingsSearchEntries) {
      expect(sections, contains(e.section), reason: e.id);
      expect(e.id.startsWith('${e.section}.'), isTrue, reason: e.id);
    }
  });
}
