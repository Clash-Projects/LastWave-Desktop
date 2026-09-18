import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/window.dart';
import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import 'theme_controller.dart';

const _sections = [
  ('account', 'Account', LucideIcons.atSign),
  ('audio', 'Audio', LucideIcons.audioWaveform),
  ('appearance', 'Appearance', LucideIcons.palette),
  ('lyrics', 'Lyrics', LucideIcons.micVocal),
  ('scrobbler', 'Scrobbler', LucideIcons.history),
  ('ytm', 'YouTube Music', LucideIcons.clapperboard),
  ('about', 'About', LucideIcons.info),
];

/// Editorial settings: ledger nav + flat form groups.
/// Replaces stacked boxed ShadCard sections with a two-column ledger
/// (nav left 200, form right flex). No nested backgrounds; hierarchy
/// from kickers + separators.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() =>
      _SettingsScreenState();
}

class _SettingsScreenState
    extends ConsumerState<SettingsScreen> {
  String _section = 'account';
  Future<void> _update(
      Future<void> Function(Prefs) fn) async {
    await fn(ref.read(prefsProvider));
    ref.read(themeControllerProvider.notifier).refresh();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 900;
    if (narrow) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.md, LwSpacing.md, LwSpacing.md, 96),
        children: [
          const EdKicker('System'),
          const Text('Settings',
              style: LwType.display),
          const SizedBox(height: LwSpacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in _sections)
                  Padding(
                    padding:
                        const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(s.$2,
                          style: LwType.label),
                      selected: _section == s.$1,
                      onSelected: (_) => setState(
                          () => _section = s.$1),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LwSpacing.md),
          _SectionBody(
              section: _section, onUpdate: _update),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 210,
          padding: const EdgeInsets.fromLTRB(
              LwSpacing.xl,
              LwSpacing.lg,
              LwSpacing.md,
              LwSpacing.lg),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const EdKicker('System'),
              const Text('Settings',
                  style: LwType.display),
              const SizedBox(height: LwSpacing.md),
              for (final s in _sections)
                _NavRow(
                  label: s.$2,
                  icon: s.$3,
                  selected: _section == s.$1,
                  onTap: () =>
                      setState(() => _section = s.$1),
                ),
            ],
          ),
        ),
        const LwSeparator.vertical(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.xl,
                LwSpacing.lg,
                LwSpacing.xl,
                96),
            children: [
              EdPage(
                maxWidth: 640,
                child: _SectionBody(
                    section: _section,
                    onUpdate: _update),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _NavRow(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LwRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: LwSpacing.sm, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius:
              BorderRadius.circular(LwRadius.sm),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 15,
                color: selected
                    ? accent
                    : (dark
                        ? LwColors.textSecondary
                        : LwColors
                            .lightTextSecondary)),
            const SizedBox(width: LwSpacing.sm),
            Text(label,
                style: LwType.body.copyWith(
                    fontWeight: selected
                        ? FontWeight.w600
                        : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}

class _SectionBody extends ConsumerWidget {
  final String section;
  final Future<void> Function(
      Future<void> Function(Prefs))
      onUpdate;
  const _SectionBody(
      {required this.section, required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (section) {
      case 'account':
        return _Account(onUpdate: onUpdate);
      case 'audio':
        return _Audio(onUpdate: onUpdate);
      case 'appearance':
        return _Appearance(onUpdate: onUpdate);
      case 'lyrics':
        return _Lyrics(onUpdate: onUpdate);
      case 'scrobbler':
        return _Scrobbler(onUpdate: onUpdate);
      case 'ytm':
        return const _Ytm();
      default:
        return const _About();
    }
  }
}

class _Group extends StatelessWidget {
  final String kicker;
  final String title;
  final Widget child;
  const _Group(
      {required this.kicker,
      required this.title,
      required this.child});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EdKicker(kicker),
        const SizedBox(height: 2),
        Text(title, style: LwType.headline),
        const SizedBox(height: LwSpacing.sm),
        child,
        const SizedBox(height: LwSpacing.lg),
        const LwSeparator.horizontal(),
        const SizedBox(height: LwSpacing.lg),
      ],
    );
  }
}

class _Account extends ConsumerWidget {
  final Future<void> Function(
      Future<void> Function(Prefs))
      onUpdate;
  const _Account({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authRepositoryProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _Group(
      kicker: 'Account',
      title: 'Last.fm connection',
      child: Row(
        children: [
          const Icon(LucideIcons.atSign,
              size: 18,
              color: LwColors.textSecondary),
          const SizedBox(width: LwSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                    auth.username.isEmpty
                        ? 'Not connected'
                        : auth.username,
                    style: LwType.title),
                Text(
                    auth.username.isEmpty
                        ? 'Scrobbling and discovery need a session'
                        : 'Last.fm connected',
                    style: LwType.caption.copyWith(
                        color: dark
                            ? LwColors.textSecondary
                            : LwColors
                                .lightTextSecondary)),
              ],
            ),
          ),
          auth.username.isEmpty
              ? LwButton(
                  onPressed: () =>
                      context.go('/welcome'),
                  child: const Text('Connect'),
                )
              : LwButton.outline(
                  onPressed: () => ref
                      .read(authRepositoryProvider
                          .notifier)
                      .signOut(),
                  child: const Text('Sign out'),
                ),
        ],
      ),
    );
  }
}

class _Audio extends ConsumerWidget {
  final Future<void> Function(
      Future<void> Function(Prefs))
      onUpdate;
  const _Audio({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        _Group(
          kicker: 'Audio',
          title: 'Streaming',
          child: Column(
            children: [
              _QualityRow(
                title: 'Streaming quality',
                value: prefs.losslessQuality,
                onChanged: (q) => onUpdate(
                    (p) => p.setLosslessQuality(q)),
              ),
              const LwSeparator.horizontal(),
              _QualityRow(
                title: 'Download quality',
                value: prefs.downloadQuality,
                onChanged: (q) => onUpdate(
                    (p) => p.setDownloadQuality(q)),
              ),
            ],
          ),
        ),
        _Group(
          kicker: 'Audio',
          title: 'Output',
          child: Column(
            children: [
              _SwitchLedger(
                value: prefs.preferLossless,
                onChanged: (v) => onUpdate(
                    (p) => p.setPreferLossless(v)),
                title: 'Prefer lossless',
                subtitle:
                    'Try lossless first, fall back to Opus',
              ),
              _SwitchLedger(
                value: prefs.downloadLyrics,
                onChanged: (v) => onUpdate(
                    (p) => p.setDownloadLyrics(v)),
                title: 'Download lyrics',
                subtitle:
                    'Save synced .lrc sidecars with downloads',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Appearance extends ConsumerWidget {
  final Future<void> Function(
      Future<void> Function(Prefs))
      onUpdate;
  const _Appearance({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final theme = ref.watch(themeControllerProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        _Group(
          kicker: 'Appearance',
          title: 'Theme',
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                theme.isLight
                    ? 'Pearl white ledger'
                    : 'Midnight ledger',
                style: LwType.caption.copyWith(
                    color: dark
                        ? LwColors.textSecondary
                        : LwColors
                            .lightTextSecondary),
              ),
              const SizedBox(height: LwSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: _ThemeSeg(
                      label: 'Midnight',
                      icon: LucideIcons.moonStar,
                      selected: !theme.isLight,
                      onTap: () async {
                        await ref
                            .read(themeControllerProvider
                                .notifier)
                            .setThemeMode(false);
                        await _applyWindowMaterial(
                            false);
                      },
                    ),
                  ),
                  const SizedBox(
                      width: LwSpacing.xs),
                  Expanded(
                    child: _ThemeSeg(
                      label: 'Pearl',
                      icon: LucideIcons.sun,
                      selected: theme.isLight,
                      onTap: () async {
                        await ref
                            .read(themeControllerProvider
                                .notifier)
                            .setThemeMode(true);
                        await _applyWindowMaterial(
                            true);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: LwSpacing.md),
              const Text('Accent colour',
                  style: LwType.title),
              const SizedBox(height: LwSpacing.xs),
              Wrap(
                spacing: LwSpacing.xs,
                children: LwColors.accentChoices
                    .map((c) => InkWell(
                          onTap: () => onUpdate((p) =>
                              p.setAccentColor(
                                  c.toARGB32())),
                          borderRadius:
                              BorderRadius.circular(20),
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: c,
                            child: theme.accent
                                        .toARGB32() ==
                                    c.toARGB32()
                                ? const Icon(
                                    LucideIcons.check,
                                    size: 14,
                                    color: Colors.white)
                                : null,
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
        _Group(
          kicker: 'Appearance',
          title: 'Surfaces',
          child: Column(
            children: [
              _SwitchLedger(
                value: prefs.amoled,
                onChanged: (v) =>
                    onUpdate((p) => p.setAmoled(v)),
                title: 'AMOLED black',
              ),
              _SwitchLedger(
                value: prefs.dynamicNowPlaying,
                onChanged: (v) => onUpdate(
                    (p) => p.setDynamicNowPlaying(v)),
                title: 'Dynamic artwork theme',
                subtitle:
                    'Tint Now Playing from album art',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Lyrics extends ConsumerWidget {
  final Future<void> Function(
      Future<void> Function(Prefs))
      onUpdate;
  const _Lyrics({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      kicker: 'Lyrics',
      title: 'Timing',
      child: _SwitchLedger(
        value: prefs.wordByWord,
        onChanged: (v) =>
            onUpdate((p) => p.setWordByWord(v)),
        title: 'Word-by-word lyrics',
        subtitle:
            'Karaoke word highlight. Off uses Apple Music line lyrics.',
      ),
    );
  }
}

class _Scrobbler extends ConsumerWidget {
  final Future<void> Function(
      Future<void> Function(Prefs))
      onUpdate;
  const _Scrobbler({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      kicker: 'Scrobbler',
      title: 'Last.fm scrobbling',
      child: Column(
        children: [
          _SwitchLedger(
            value: prefs.scrobblerEnabled,
            onChanged: (v) => onUpdate(
                (p) => p.setScrobbler(enabled: v)),
            title: 'Enable scrobbling',
            subtitle:
                'Requires a write-capable session',
          ),
          _SwitchLedger(
            value: prefs.scrobbleNowPlaying,
            onChanged: (v) => onUpdate((p) =>
                p.setScrobbler(nowPlaying: v)),
            title: 'Now playing updates',
          ),
          Padding(
            padding: const EdgeInsets.only(
                top: LwSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                      'Scrobble at ${prefs.scrobblePercent}% of track',
                      style: LwType.title),
                ),
                SizedBox(
                  width: 180,
                  child: LwSlider(
                    value: prefs.scrobblePercent
                        .toDouble(),
                    min: 25,
                    max: 90,
                    onChanged: (v) => onUpdate((p) =>
                        p.setScrobbler(
                            percent: v.round())),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Ytm extends ConsumerWidget {
  const _Ytm();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tube = ref.watch(innerTubeProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _Group(
      kicker: 'Catalogue',
      title: 'YouTube Music',
      child: Row(
        children: [
          const Icon(LucideIcons.clapperboard,
              size: 18,
              color: LwColors.textSecondary),
          const SizedBox(width: LwSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                    tube.connection.connected
                        ? 'Connected'
                        : 'Not connected',
                    style: LwType.title),
                Text(
                    'Personal library, history and uploads',
                    style: LwType.caption.copyWith(
                        color: dark
                            ? LwColors.textSecondary
                            : LwColors
                                .lightTextSecondary)),
              ],
            ),
          ),
          tube.connection.connected
              ? LwButton.outline(
                  onPressed: () async {
                    await tube.signOut();
                    if (context.mounted) {
                      showToast(context,
                          'YouTube Music disconnected.');
                    }
                  },
                  child:
                      const Text('Disconnect'),
                )
              : LwButton(
                  onPressed: () =>
                      _ytConnect(context, ref),
                  child: const Text('Connect'),
                ),
        ],
      ),
    );
  }

  Future<void> _ytConnect(
      BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final cookies = await showLwDialog<String>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: [
          const Text('Connect YouTube Music',
              style: LwType.headline),
          const SizedBox(height: 4),
          const Text(
              'Paste music.youtube.com cookie header. Stored in OS keychain.',
              style: LwType.caption),
          const SizedBox(height: LwSpacing.sm),
          SizedBox(
            width: 440,
            child: LwTextField(
              controller: controller,
              hint: '__Secure-3PAPISID=…; SAPISID=…',
            ),
          ),
          const SizedBox(height: LwSpacing.md),
          Row(
            mainAxisAlignment:
                MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(),
                  child: const Text('Cancel')),
              const SizedBox(width: 8),
              LwButton(
                  onPressed: () =>
                      Navigator.of(context).pop(
                          controller.text.trim()),
                  child: const Text('Connect')),
            ],
          ),
        ],
      ),
    );
    controller.dispose();
    if (cookies != null && cookies.isNotEmpty) {
      await ref.read(innerTubeProvider).connect(cookies);
      if (context.mounted) {
        showToast(context, 'YouTube Music connected.');
      }
    }
  }
}

class _About extends StatelessWidget {
  const _About();
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _Group(
      kicker: 'System',
      title: 'About',
      child: Text(
        'LastWave Desktop · Lossless: ${AppEnv.losslessCatalogLabel} · '
        'Lyrics key: ${AppEnv.lyricsApiKey.isNotEmpty ? 'set' : 'missing'}',
        style: LwType.caption.copyWith(
            color: dark
                ? LwColors.textSecondary
                : LwColors.lightTextSecondary),
      ),
    );
  }
}

Future<void> _applyWindowMaterial(bool isLight) async {
  try {
    await applyWindowMaterial(isLight: isLight);
  } catch (_) {}
}

class _ThemeSeg extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeSeg(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: LwMotion.fast,
        padding: const EdgeInsets.symmetric(
            vertical: LwSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius:
              BorderRadius.circular(LwRadius.sm),
          border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.5)
                  : (dark
                      ? LwColors.outline
                      : LwColors.lightOutline)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 15,
                color: selected
                    ? accent
                    : (dark
                        ? LwColors.textSecondary
                        : LwColors
                            .lightTextSecondary)),
            const SizedBox(width: 6),
            Text(label, style: LwType.label),
          ],
        ),
      ),
    );
  }
}

class _QualityRow extends StatelessWidget {
  final String title;
  final int value;
  final ValueChanged<int> onChanged;
  const _QualityRow({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: LwSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(title, style: LwType.title),
                Text(AudioQualityTiers.label(value),
                    style: LwType.caption.copyWith(
                        color: dark
                            ? LwColors.textSecondary
                            : LwColors
                                .lightTextSecondary)),
              ],
            ),
          ),
          DropdownButton<int>(
            value: null,
            hint: Text(AudioQualityTiers.label(value)),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            items: const [
              DropdownMenuItem(
                  value: 27,
                  child: Text('Hi-Res · 24/192')),
              DropdownMenuItem(
                  value: 7,
                  child: Text('Hi-Res · 24/96')),
              DropdownMenuItem(
                  value: 6,
                  child: Text('Lossless · 16/44.1')),
              DropdownMenuItem(
                  value: 5,
                  child: Text('320k MP3')),
              DropdownMenuItem(
                  value: -1,
                  child: Text('Opus · YouTube')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SwitchLedger extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;
  const _SwitchLedger(
      {required this.value,
      required this.onChanged,
      required this.title,
      this.subtitle});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: LwSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(title, style: LwType.title),
                if (subtitle != null)
                  Text(subtitle!,
                      style: LwType.caption.copyWith(
                          color: dark
                              ? LwColors.textSecondary
                              : LwColors
                                  .lightTextSecondary)),
              ],
            ),
          ),
          const SizedBox(width: LwSpacing.sm),
          LwSwitch(
              value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
