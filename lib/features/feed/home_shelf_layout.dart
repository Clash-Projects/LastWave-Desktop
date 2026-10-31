import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../search/shared_providers.dart';

/// kv_store key for the home shelf order and hidden set.
const homeShelfLayoutKey = 'home_shelf_layout';

/// Stable ids for the shelves [WaveHomePage] builds.
///
/// A shelf added to [HomeShelfCatalog.defaults] later still shows up for
/// people who already saved a layout: [resolveHomeShelfOrder] leaves any
/// id the save never mentioned in its default slot.
abstract final class HomeShelfId {
  static const mixes = 'mixes';
  static const youtube = 'youtube';
  static const quickPicks = 'quick_picks';
  static const continueListening = 'continue';
  static const because = 'because';
  static const albums = 'albums';
  static const artists = 'artists';
  static const friends = 'friends';
  static const charts = 'charts';
  static const fresh = 'fresh';
  static const releases = 'releases';
  static const popular = 'popular';
  static const podcasts = 'podcasts';
}

abstract final class HomeShelfCatalog {
  /// Visual order on a fresh Home, top to bottom.
  static const defaults = <String>[
    HomeShelfId.mixes,
    HomeShelfId.youtube,
    HomeShelfId.quickPicks,
    HomeShelfId.continueListening,
    HomeShelfId.podcasts,
    HomeShelfId.because,
    HomeShelfId.albums,
    HomeShelfId.artists,
    HomeShelfId.friends,
    HomeShelfId.charts,
    HomeShelfId.fresh,
    HomeShelfId.releases,
    HomeShelfId.popular,
  ];

  static const labels = <String, String>{
    HomeShelfId.mixes: 'Mixes',
    HomeShelfId.youtube: 'YouTube Music',
    HomeShelfId.quickPicks: 'Quick Picks',
    HomeShelfId.continueListening: 'Continue Listening',
    HomeShelfId.because: 'Because You Listened',
    HomeShelfId.albums: 'Albums',
    HomeShelfId.artists: 'Artists',
    HomeShelfId.friends: 'Friends',
    HomeShelfId.charts: 'Charts',
    HomeShelfId.fresh: 'Fresh Finds',
    HomeShelfId.releases: 'New Releases',
    HomeShelfId.popular: 'Popular',
    HomeShelfId.podcasts: 'Podcasts',
  };

  static String label(String id) => labels[id] ?? id;
}

/// Saved order merged with [defaults].
///
/// Ids present in [saved] keep that relative order. Ids [saved] never
/// mentions — a shelf this build added — stay at their default index
/// instead of being appended or dropped.
List<String> resolveHomeShelfOrder(
  List<String> saved,
  List<String> defaults,
) {
  if (saved.isEmpty || defaults.isEmpty) {
    return List<String>.of(defaults);
  }
  final known = defaults.toSet();
  final mentioned = <String>[];
  final seen = <String>{};
  for (final id in saved) {
    if (!known.contains(id) || !seen.add(id)) continue;
    mentioned.add(id);
  }
  if (mentioned.isEmpty) return List<String>.of(defaults);
  if (mentioned.length == defaults.length) return mentioned;

  final mentionedSet = mentioned.toSet();
  final placed = List<String?>.filled(defaults.length, null);
  for (var i = 0; i < defaults.length; i++) {
    if (!mentionedSet.contains(defaults[i])) {
      placed[i] = defaults[i];
    }
  }
  var cursor = 0;
  for (final id in mentioned) {
    while (cursor < placed.length && placed[cursor] != null) {
      cursor++;
    }
    if (cursor >= placed.length) break;
    placed[cursor] = id;
    cursor++;
  }
  return [for (final id in placed) ?id];
}

class HomeShelfLayout {
  final List<String> order;
  final Set<String> hidden;

  const HomeShelfLayout({
    required this.order,
    required this.hidden,
  });

  factory HomeShelfLayout.fresh() => HomeShelfLayout(
        order: List<String>.of(HomeShelfCatalog.defaults),
        hidden: const {},
      );

  List<String> get visibleIds =>
      [for (final id in order) if (!hidden.contains(id)) id];

  HomeShelfLayout copyWith({
    List<String>? order,
    Set<String>? hidden,
  }) =>
      HomeShelfLayout(
        order: order ?? this.order,
        hidden: hidden ?? this.hidden,
      );

  String encode() => jsonEncode({
        'order': order,
        'hidden': hidden.toList(),
      });

  factory HomeShelfLayout.decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return HomeShelfLayout.fresh();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return HomeShelfLayout.fresh();
      final orderRaw = decoded['order'];
      final hiddenRaw = decoded['hidden'];
      final saved = orderRaw is List
          ? [for (final id in orderRaw) id.toString()]
          : const <String>[];
      final hidden = hiddenRaw is List
          ? {for (final id in hiddenRaw) id.toString()}
          : <String>{};
      final known = HomeShelfCatalog.defaults.toSet();
      return HomeShelfLayout(
        order: resolveHomeShelfOrder(saved, HomeShelfCatalog.defaults),
        hidden: hidden.where(known.contains).toSet(),
      );
    } catch (_) {
      return HomeShelfLayout.fresh();
    }
  }
}

class HomeShelfLayoutNotifier extends StateNotifier<HomeShelfLayout> {
  HomeShelfLayoutNotifier(this._db)
      : super(HomeShelfLayout.decode(_db.kvGet(homeShelfLayoutKey)));

  final AppDatabase _db;

  void _persist() {
    _db.kvSet(homeShelfLayoutKey, state.encode());
  }

  void toggle(String id) {
    if (!state.order.contains(id)) return;
    final hidden = Set<String>.of(state.hidden);
    if (!hidden.remove(id)) hidden.add(id);
    state = state.copyWith(hidden: hidden);
    _persist();
  }

  /// [newIndex] comes from [ReorderableListView.onReorderItem], which
  /// is already the index in the list after the row is removed.
  void reorder(int oldIndex, int newIndex) {
    final order = List<String>.of(state.order);
    if (oldIndex < 0 || oldIndex >= order.length) return;
    if (newIndex < 0 || newIndex >= order.length || oldIndex == newIndex) {
      return;
    }
    final id = order.removeAt(oldIndex);
    order.insert(newIndex, id);
    state = state.copyWith(order: order);
    _persist();
  }

  void reset() {
    state = HomeShelfLayout.fresh();
    _persist();
  }
}

final homeShelfLayoutProvider =
    StateNotifierProvider<HomeShelfLayoutNotifier, HomeShelfLayout>((ref) {
  return HomeShelfLayoutNotifier(ref.watch(databaseProvider));
});
