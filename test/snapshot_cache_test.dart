import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/storage/app_database.dart';

void main() {
  late AppDatabase db;
  final t0 = DateTime(2026, 11, 4, 12);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  setUp(() => db = AppDatabase.inMemory());

  test('stores and returns a value with its save time', () {
    db.cachePut('a', 'home', '{"x":1}', now: at(0));
    final row = db.cacheGet('a', now: at(1))!;
    expect(row.value, '{"x":1}');
    expect(row.savedAt, at(0));
    expect(db.cacheGet('missing'), isNull);
  });

  test('a rewrite replaces the value and the save time', () {
    db.cachePut('a', 'home', 'old', now: at(0));
    db.cachePut('a', 'home', 'new', now: at(5));
    final row = db.cacheGet('a')!;
    expect(row.value, 'new');
    expect(row.savedAt, at(5));
    expect(db.cacheStats()['home']!.entries, 1);
  });

  test('a group is trimmed to its cap, least recently used first', () {
    final cap = AppDatabase.cacheCaps['home']!;
    for (var i = 0; i < cap; i++) {
      db.cachePut('k$i', 'home', 'v$i', now: at(i));
    }
    // Reading k0 makes it the most recently used...
    db.cacheGet('k0', now: at(cap + 1));
    // ...so the next write evicts k1, the oldest untouched entry.
    db.cachePut('new', 'home', 'v', now: at(cap + 2));
    expect(db.cacheStats()['home']!.entries, cap);
    expect(db.cacheGet('k0'), isNotNull);
    expect(db.cacheGet('k1'), isNull);
    expect(db.cacheGet('new'), isNotNull);
  });

  test('groups are capped independently', () {
    final cap = AppDatabase.cacheCaps['home']!;
    for (var i = 0; i < cap + 5; i++) {
      db.cachePut('h$i', 'home', 'v', now: at(i));
    }
    db.cachePut('l0', 'lyrics', 'v', now: at(0));
    final stats = db.cacheStats();
    expect(stats['home']!.entries, cap);
    expect(stats['lyrics']!.entries, 1);
  });

  test('unlisted groups fall back to the default cap', () {
    for (var i = 0; i < AppDatabase.defaultCacheCap + 3; i++) {
      db.cachePut('x$i', 'mystery', 'v', now: at(i));
    }
    expect(db.cacheStats()['mystery']!.entries, AppDatabase.defaultCacheCap);
  });

  test('clear drops one group or everything', () {
    db.cachePut('a', 'home', 'v');
    db.cachePut('b', 'lyrics', 'vv');
    expect(db.cacheStats()['lyrics']!.chars, 2);

    db.cacheClear(group: 'home');
    expect(db.cacheGet('a'), isNull);
    expect(db.cacheGet('b'), isNotNull);

    db.cacheClear();
    expect(db.cacheStats(), isEmpty);
  });

}
