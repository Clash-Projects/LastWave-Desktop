import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../lastfm/home_repository.dart';

final _friendsProvider =
    FutureProvider.autoDispose<List<FriendEntry>>((ref) {
  return ref.watch(homeRepositoryProvider).fetchFriends();
});

/// Friends & social feed (mirrors Android FriendsScreen).
class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(_friendsProvider);
    return friends.when(
      loading: () => ListView(
        padding: const EdgeInsets.all(LwSpacing.lg),
        children: const [
          SkeletonBox(width: 200, height: 26),
          SizedBox(height: 16),
          SkeletonRow(count: 8),
        ],
      ),
      error: (e, _) => EmptyState(
        icon: LwIcons.cloudOff,
        title: 'Could not load friends',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () =>
            ref.invalidate(_friendsProvider),
      ),
      data: (list) => ListView(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
        children: [
          const Text('Friends',
              style: LwType.display),
          const SizedBox(height: 4),
          const Text(
            'Browse friends’ listening habits and play their taste.',
            style: LwType.body,
          ),
          const SizedBox(height: LwSpacing.md),
          if (list.isEmpty)
            const EmptyState(
              icon: LwIcons.users,
              title: 'No friends yet',
              subtitle:
                  'Add friends on Last.fm — they will show up here.',
            )
          else
            ...list.map((f) => ListTile(
                  leading: f.avatarUrl.isEmpty
                      ? const CircleAvatar(
                          child:
                              Icon(LwIcons.user,
                                  size: 16))
                      : CircleAvatar(
                          backgroundImage:
                              NetworkImage(f.avatarUrl)),
                  title: Text(f.name),
                  subtitle: f.realName.isNotEmpty
                      ? Text(f.realName)
                      : null,
                  trailing: const Icon(
                      LwIcons.chevronRight,
                      size: 16),
                  onTap: () {
                    ref
                        .read(viewingProfileProvider
                            .notifier)
                        .view(f.name);
                    context.go('/profile');
                  },
                )),
        ],
      ),
    );
  }
}
