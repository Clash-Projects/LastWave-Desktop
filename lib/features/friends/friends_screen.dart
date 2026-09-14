import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeletons.dart';
import '../lastfm/home_repository.dart';

final _friendsProvider =
    FutureProvider.autoDispose<List<FriendEntry>>((ref) {
  return ref.watch(homeRepositoryProvider).fetchFriends();
});

/// Editorial friends ledger: masthead + avatar ledger rows.
class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final friends = ref.watch(_friendsProvider);
    return friends.when(
      loading: () => ListView(
        padding: const EdgeInsets.all(LwSpacing.xl),
        children: const [
          SkeletonBox(width: 200, height: 26),
          SizedBox(height: LwSpacing.md),
          SkeletonRow(count: 8),
        ],
      ),
      error: (e, _) => EmptyState(
        icon: LucideIcons.cloudOff,
        title: 'Could not load friends',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () =>
            ref.invalidate(_friendsProvider),
      ),
      data: (list) => ListView(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 96),
        children: [
          EdPage(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const EdKicker('Social'),
                const Text('Friends',
                    style: LwType.display),
                const SizedBox(height: 4),
                Text(
                  'Browse friends’ listening habits and play their taste.',
                  style: LwType.body.copyWith(
                      color: dark
                          ? LwColors.textSecondary
                          : LwColors
                              .lightTextSecondary),
                ),
                const SizedBox(height: LwSpacing.md),
                const EdLedgerHeader(metaLabel: ''),
                if (list.isEmpty)
                  const EmptyState(
                    icon: LucideIcons.users,
                    title: 'No friends yet',
                    subtitle:
                        'Add friends on Last.fm — they will show up here.',
                  )
                else
                  ...list.map((f) => InkWell(
                        onTap: () {
                          ref
                              .read(viewingProfileProvider
                                  .notifier)
                              .view(f.name);
                          context.go('/profile');
                        },
                        borderRadius:
                            BorderRadius.circular(
                                LwRadius.sm),
                        child: Padding(
                          padding: const EdgeInsets
                              .symmetric(
                              horizontal:
                                  LwSpacing.sm,
                              vertical:
                                  LwSpacing.xs),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: dark
                                    ? LwColors
                                        .surfaceOverlay
                                    : LwColors
                                        .lightSurfaceOverlay,
                                backgroundImage: f.avatarUrl
                                        .isNotEmpty
                                    ? NetworkImage(
                                        f.avatarUrl)
                                    : null,
                                child: f.avatarUrl
                                        .isEmpty
                                    ? Text(
                                        f.name.isNotEmpty
                                            ? f.name[0]
                                                .toUpperCase()
                                            : '?',
                                        style:
                                            LwType.title)
                                    : null,
                              ),
                              const SizedBox(
                                  width: LwSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  children: [
                                    Text(f.name,
                                        style:
                                            LwType.title),
                                    if (f.realName
                                        .isNotEmpty)
                                      Text(f.realName,
                                          style: LwType
                                              .caption
                                              .copyWith(
                                                  color: dark
                                                      ? LwColors
                                                          .textSecondary
                                                      : LwColors
                                                          .lightTextSecondary)),
                                  ],
                                ),
                              ),
                              const Icon(
                                  LucideIcons
                                      .chevronRight,
                                  size: 15,
                                  color: LwColors
                                      .textTertiary),
                            ],
                          ),
                        ),
                      )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
