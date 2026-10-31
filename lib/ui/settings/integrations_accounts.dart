import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/canvas/canvas_clip.dart';
import '../../features/spotify/spotify_library.dart';
import '../../features/spotify/spotify_login.dart';
import '../../features/spotify/spotify_session.dart';
import '../../l10n/app_language.dart';
import '../../l10n/shell_strings.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';
import '../../features/innertube/innertube_api.dart';
import '../theme/tokens.dart';
import 'settings_search.dart';
import '../../features/library/playlists.dart';

/// Settings → Integrations: Spotify session and the Jam server URL.
class IntegrationsAccounts extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const IntegrationsAccounts({super.key, required this.onUpdate});

  @override
  ConsumerState<IntegrationsAccounts> createState() =>
      _IntegrationsAccountsState();
}

class _IntegrationsAccountsState extends ConsumerState<IntegrationsAccounts> {
  final _cookie = TextEditingController();
  final _jam = TextEditingController();
  bool _connected = false;
  bool _busy = false;
  String _status = '';
  SpotifyImportProgress? _progress;
  SpotifyAccount? _account;

  @override
  void initState() {
    super.initState();
    _jam.text = '';
    _load();
  }

  Future<void> _load() async {
    final session = ref.read(spotifySessionProvider);
    final on = await session.hasSession();
    final account = on ? await session.account() : null;
    if (!mounted) return;
    setState(() {
      _connected = on;
      _account = account;
      _jam.text = ref.read(prefsProvider).jamServerUrl;
    });
  }

  @override
  void dispose() {
    _cookie.dispose();
    _jam.dispose();
    super.dispose();
  }

  Future<void> _saveCookie(String raw) async {
    final clean = cleanSpDc(raw);
    if (clean.isEmpty) {
      setState(() => _status = 'Paste an sp_dc value first.');
      return;
    }
    final session = ref.read(spotifySessionProvider);
    await session.saveSpDc(clean);
    final token = await session.personalToken();
    ref.invalidate(canvasClipProvider);
    _cookie.clear();
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      setState(() {
        _connected = false;
        _account = null;
        _status = session.lastFailure ??
            'Spotify did not accept this cookie.';
      });
      return;
    }
    final account = await session.account();
    if (!mounted) return;
    setState(() {
      _connected = true;
      _account = account;
      _status = 'Spotify session saved.';
    });
  }

  Future<void> _browser() async {
    setState(() {
      _busy = true;
      _status = 'Waiting for sp_dc in the browser window…';
    });
    final value = await spotifyBrowserLogin();
    if (!mounted) return;
    if (value == null || value.isEmpty) {
      setState(() {
        _busy = false;
        _status = 'No sp_dc cookie yet. You can paste one instead.';
      });
      return;
    }
    await _saveCookie(value);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    await ref.read(spotifySessionProvider).clear();
    ref.invalidate(canvasClipProvider);
    if (!mounted) return;
    setState(() {
      _connected = false;
      _account = null;
      _status = 'Spotify signed out. Playback is unchanged.';
    });
  }

  Future<void> _import(bool liked) async {
    setState(() {
      _busy = true;
      _progress = null;
      _status = liked
          ? 'Reading Liked Songs…'
          : 'Reading your Spotify playlists…';
    });
    try {
      final importer = ref.read(spotifyLibraryProvider);
      final api = ref.read(innerTubeProvider);
      final playlists = ref.read(playlistRepositoryProvider.notifier);
      void onProgress(SpotifyImportProgress progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _status = '';
        });
      }

      final count = liked
          ? await importer.importLiked(
              api: api,
              playlists: playlists,
              onProgress: onProgress,
            )
          : await importer.importPlaylists(
              api: api,
              playlists: playlists,
              onProgress: onProgress,
            );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _status = liked
            ? 'Matched $count Liked Songs into a local playlist.'
            : 'Imported $count Spotify playlists.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _status = error.toString();
      });
    }
  }

  Widget _avatar(ShellStrings strings) {
    final photo = _account?.imageUrl ?? '';
    if (_connected && photo.isNotEmpty) {
      return WaveArtwork.circle(
        url: photo,
        size: 40,
        label: _title(strings),
        upgrade: false,
      );
    }
    return const Icon(FluentIcons.music_in_collection, size: 18);
  }

  String _title(ShellStrings strings) {
    final name = _account?.name ?? '';
    if (_connected && name.isNotEmpty) return name;
    return _connected ? strings('connected') : strings('signedOut');
  }

  String _subtitle(ShellStrings strings) {
    if (!_connected) return 'The cookie stays in the system keychain';
    final handle = _account?.handle ?? '';
    if (handle.isEmpty) return strings('connected');
    final at = handle.startsWith('@') ? handle : '@$handle';
    return '$at · ${strings('connected')}';
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(shellStringsProvider);
    final canvas = ref.watch(prefsProvider).spotifyCanvasEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTarget(
          id: 'integrations.spotify',
          child: _AccountCard(
            title: strings('spotify'),
            subtitle: strings('spotifyBody'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _avatar(strings),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _title(strings),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle,
                          ),
                          Text(
                            _subtitle(strings),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_connected) ...[
                      const SizedBox(width: 10),
                      WaveButton(
                        onPressed: _busy ? null : _disconnect,
                        child: Text(strings('spotifyDisconnect')),
                      ),
                    ],
                  ],
                ),
                if (!_connected) ...[
                  const SizedBox(height: 12),
                  TextBox(
                    controller: _cookie,
                    placeholder: 'sp_dc',
                    decoration: waveInputDecoration(),
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      WaveFilledButton(
                        onPressed:
                            _busy ? null : () => _saveCookie(_cookie.text),
                        child: Text(strings('spotifyPasteHint')),
                      ),
                      WaveButton(
                        onPressed: _busy ? null : _browser,
                        child: Text(strings('spotifyBrowser')),
                      ),
                    ],
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      WaveButton(
                        onPressed: _busy ? null : () => _import(false),
                        child: Text(strings('spotifyImport')),
                      ),
                      WaveButton(
                        onPressed: _busy ? null : () => _import(true),
                        child: Text(strings('spotifyLiked')),
                      ),
                    ],
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 12),
                  Text(
                    _progress?.headline ?? _status,
                    style: WaveType.trackTitle,
                  ),
                  if (_progress != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      _progress!.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  ProgressBar(
                    value: _progress == null ? null : _progress!.fraction * 100,
                  ),
                ] else if (_status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _status,
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Container(height: 1, color: waveDivider(context)),
                SettingsTarget(
                  id: 'integrations.spotify.canvas',
                  child: _SwitchLine(
                    value: canvas,
                    title: strings('spotifyCanvas'),
                    subtitle: strings('spotifyCanvasHint'),
                    onChanged: (value) {
                      widget.onUpdate((p) => p.setSpotifyCanvasEnabled(value));
                      ref.invalidate(canvasClipProvider);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTarget(
          id: 'integrations.jam',
          child: _AccountCard(
            title: strings('jamServer'),
            subtitle: 'Rooms connect to this websocket',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextBox(
                  controller: _jam,
                  placeholder: 'wss://jam.clashprojects.qd.je/ws',
                  decoration: waveInputDecoration(),
                  onSubmitted: (value) =>
                      widget.onUpdate((p) => p.setJamServerUrl(value)),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: WaveButton(
                    onPressed: () =>
                        widget.onUpdate((p) => p.setJamServerUrl(_jam.text)),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Same header-and-body card as YouTube Music and Discord on this page.
class _AccountCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _AccountCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          decoration: BoxDecoration(
            color: theme.resources.cardBackgroundFillColorDefault,
            border: Border.all(color: stroke),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(WaveRadius.floating),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: WaveType.sectionTitle),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.resources.cardBackgroundFillColorSecondary,
            border: Border(
              left: BorderSide(color: stroke),
              right: BorderSide(color: stroke),
              bottom: BorderSide(color: stroke),
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(WaveRadius.floating),
            ),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _SwitchLine extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;
  const _SwitchLine({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: WaveType.trackTitle),
                Text(
                  subtitle,
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ToggleSwitch(checked: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
