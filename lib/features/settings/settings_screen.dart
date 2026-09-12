import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../design_system/tokens.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import 'theme_controller.dart';

/// Desktop settings: account, streaming, appearance, lyrics,
/// scrobbler, YouTube Music, about. Mirrors Android SettingsScreen
/// sections adapted for desktop.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() =>
      _SettingsScreenState();
}

class _SettingsScreenState
    extends ConsumerState<SettingsScreen> {
  Future<void> _update(
      Future<void> Function(Prefs) fn) async {
    await fn(ref.read(prefsProvider));
    ref.read(themeControllerProvider.notifier).refresh();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final auth = ref.watch(authRepositoryProvider);
    final theme = ref.watch(themeControllerProvider);
    final tube = ref.watch(innerTubeProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        const Text('Settings', style: LwType.display),
        const SizedBox(height: LwSpacing.lg),
        _Section(
          title: 'Account',
          children: [
            ListTile(
              leading: const Icon(
                  LwIcons.atSign,
                  color: LwColors.textSecondary),
              title: Text(auth.username.isEmpty
                  ? 'Not connected'
                  : auth.username),
              subtitle: Text(auth.username.isEmpty
                  ? 'Connect Last.fm for scrobbling and discovery'
                  : 'Last.fm connected'),
              trailing: auth.username.isEmpty
                  ? FilledButton(
                      onPressed: () =>
                          context.go('/login'),
                      child:
                          const Text('Connect'),
                    )
                  : OutlinedButton(
                      onPressed: () => ref
                          .read(authRepositoryProvider
                              .notifier)
                          .signOut(),
                      child:
                          const Text('Sign out'),
                    ),
            ),
          ],
        ),
        _Section(
          title: 'Audio & streaming',
          children: [
            _QualityTile(
              title: 'Streaming quality',
              value: prefs.losslessQuality,
              onChanged: (q) =>
                  _update((p) => p.setLosslessQuality(q)),
            ),
            _QualityTile(
              title: 'Download quality',
              value: prefs.downloadQuality,
              onChanged: (q) =>
                  _update((p) => p.setDownloadQuality(q)),
            ),
            SwitchListTile(
              title: const Text('Prefer lossless'),
              subtitle: const Text(
                  'Try the lossless backend first, fall back to Opus'),
              value: prefs.preferLossless,
              onChanged: (v) =>
                  _update((p) => p.setPreferLossless(v)),
            ),
            SwitchListTile(
              title: const Text('Bit-perfect output'),
              subtitle: const Text(
                  'Bypass processing for untouched audio'),
              value: prefs.bitPerfect,
              onChanged: (v) =>
                  _update((p) => p.setBitPerfect(v)),
            ),
            SwitchListTile(
              title: const Text('Download lyrics'),
              subtitle: const Text(
                  'Save synced .lrc sidecars with downloads'),
              value: prefs.downloadLyrics,
              onChanged: (v) =>
                  _update((p) => p.setDownloadLyrics(v)),
            ),
          ],
        ),
        _Section(
          title: 'Appearance',
          children: [
            ListTile(
              title: const Text('Accent colour'),
              subtitle: Wrap(
                spacing: 8,
                children: LwColors.accentChoices
                    .map((c) => InkWell(
                          onTap: () => _update((p) =>
                              p.setAccentColor(
                                  c.toARGB32())),
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: c,
                            child: theme.accent
                                        .toARGB32() ==
                                    c.toARGB32()
                                ? const Icon(
                                    LwIcons.check,
                                    size: 14,
                                    color: Colors.white)
                                : null,
                          ),
                        ))
                    .toList(),
              ),
            ),
            SwitchListTile(
              title: const Text('AMOLED black'),
              value: prefs.amoled,
              onChanged: (v) =>
                  _update((p) => p.setAmoled(v)),
            ),
            SwitchListTile(
              title:
                  const Text('Dynamic artwork theme'),
              subtitle: const Text(
                  'Tint Now Playing from album art'),
              value: prefs.dynamicNowPlaying,
              onChanged: (v) => _update(
                  (p) => p.setDynamicNowPlaying(v)),
            ),
          ],
        ),
        _Section(
          title: 'Lyrics',
          children: [
            SwitchListTile(
              title:
                  const Text('Word-by-word timing'),
              subtitle: const Text(
                  'Race word-synced providers first'),
              value: prefs.wordByWord,
              onChanged: (v) =>
                  _update((p) => p.setWordByWord(v)),
            ),
          ],
        ),
        _Section(
          title: 'Scrobbler',
          children: [
            SwitchListTile(
              title:
                  const Text('Enable scrobbling'),
              subtitle: const Text(
                  'Requires a write-capable Last.fm session'),
              value: prefs.scrobblerEnabled,
              onChanged: (v) => _update(
                  (p) => p.setScrobbler(enabled: v)),
            ),
            SwitchListTile(
              title:
                  const Text('Now playing updates'),
              value: prefs.scrobbleNowPlaying,
              onChanged: (v) => _update((p) =>
                  p.setScrobbler(nowPlaying: v)),
            ),
            ListTile(
              title: Text(
                  'Scrobble at ${prefs.scrobblePercent}% of track'),
              subtitle: Slider(
                value: prefs.scrobblePercent.toDouble(),
                min: 25,
                max: 90,
                divisions: 13,
                label: '${prefs.scrobblePercent}%',
                onChanged: (v) => _update((p) =>
                    p.setScrobbler(percent: v.round())),
              ),
            ),
          ],
        ),
        _Section(
          title: 'YouTube Music',
          children: [
            ListTile(
              leading: const Icon(
                  LwIcons.youtube,
                  color: LwColors.textSecondary),
              title: Text(tube.connection.connected
                  ? 'Connected'
                  : 'Not connected'),
              subtitle: const Text(
                  'Optional: personal library, history and uploads'),
              trailing: tube.connection.connected
                  ? OutlinedButton(
                      onPressed: () async {
                        await tube.signOut();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(
                                  content: Text(
                                      'YouTube Music disconnected')));
                        }
                      },
                      child:
                          const Text('Disconnect'),
                    )
                  : FilledButton(
                      onPressed: () =>
                          _ytConnect(context, ref),
                      child:
                          const Text('Connect'),
                    ),
            ),
          ],
        ),
        _Section(
          title: 'About',
          children: [
            ListTile(
              title: const Text('LastWave Desktop'),
              subtitle: Text(
                'Lossless backend: ${AppEnv.hasLosslessBackend ? 'configured' : 'not configured'} · '
                'Lyrics key: ${AppEnv.lyricsApiKey.isNotEmpty ? 'set' : 'missing'}',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _ytConnect(
      BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final cookies = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
            'Connect YouTube Music',
            style: LwType.title),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste your music.youtube.com cookie header (logged-in browser → devtools → request headers → Cookie). Stored in the OS keychain.',
                style: LwType.caption,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText:
                      '__Secure-3PAPISID=…; SAPISID=…',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context)
                  .pop(controller.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
    if (cookies != null && cookies.isNotEmpty) {
      await ref.read(innerTubeProvider).connect(cookies);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('YouTube Music connected')));
      }
    }
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(
      {required this.title, required this.children});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: LwType.label.copyWith(
                color: LwColors.textTertiary)),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: LwColors.surfaceRaised,
            borderRadius:
                BorderRadius.circular(LwRadius.md),
            border:
                Border.all(color: LwColors.outlineSoft),
          ),
          child: Column(children: children),
        ),
        const SizedBox(height: LwSpacing.lg),
      ],
    );
  }
}

class _QualityTile extends StatelessWidget {
  final String title;
  final int value;
  final ValueChanged<int> onChanged;
  const _QualityTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle:
          Text(AudioQualityTiers.label(value)),
      trailing: DropdownButton<int>(
        value: value,
        underline: const SizedBox.shrink(),
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
              value: 5, child: Text('320k MP3')),
          DropdownMenuItem(
              value: -1,
              child: Text('Opus · YouTube')),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
