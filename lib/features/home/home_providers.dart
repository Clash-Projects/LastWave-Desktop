import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';

/// Home data providers: feed sections and new-release records load
/// independently so partial data still renders a rich page.
final feedProvider = FutureProvider<FeedData>((ref) {
  return ref.watch(feedRepositoryProvider).loadFeed();
});

final newAlbumsProvider =
    FutureProvider<List<YouTubeMusicEntity>>((ref) {
  return ref
      .watch(feedRepositoryProvider)
      .fetchNewReleaseAlbums();
});
