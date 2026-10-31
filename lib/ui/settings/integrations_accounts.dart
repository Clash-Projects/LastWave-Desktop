import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/canvas/canvas_clip.dart';
import '../../features/spotify/spotify_library.dart';
import '../../features/spotify/spotify_login.dart';
import '../../features/spotify/spotify_session.dart';
import '../../l10n/app_language.dart';
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

  @override
  void initState() {
    super.initState();
    _jam.text = '';
    _load();
  }

  Future<void> _load() async {
    final on = await ref.read(spotifySessionProvider).hasSession();
    if (!mounted) return;
    setState(() {
      _connected = on;
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
    await ref.read(spotifySessionProvider).saveSpDc(clean);
    ref.invalidate(canvasClipProvider);
    _cookie.clear();
    if (!mounted) return;
    setState(() {
      _connected = true;
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
      _status = 'Spotify signed out. Playback is unchanged.';
    });
  }

  Future<void> _import(bool liked) async {
    final strings = ref.read(shellStringsProvider);
    setState(() {
      _busy = true;
      _status = liked ? strings('spotifyLiked') : strings('spotifyImport');
    });
    try {
      final importer = ref.read(spotifyLibraryProvider);
      final api = ref.read(innerTubeProvider);
      final playlists = ref.read(playlistRepositoryProvider.notifier);
      final count = liked
          ? await importer.importLiked(
              api: api,
              playlists: playlists,
              onProgress: (p) {
                if (mounted) setState(() => _status = p.message);
              },
            )
          : await importer.importPlaylists(
              api: api,
              playlists: playlists,
              onProgress: (p) {
                if (mounted) {
                  setState(() => _status = '${p.message} (${p.done}/${p.total})');
                }
              },
            );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = liked
            ? 'Matched $count Liked Songs into a local playlist.'
            : 'Imported $count Spotify playlists.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = error.toString();
      });
    }
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(strings('spotify'), style: WaveType.sectionTitle),
              const SizedBox(height: 6),
              Text(
                strings('spotifyBody'),
                style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
              const SizedBox(height: 4),
              Text(
                _connected ? strings('connected') : strings('signedOut'),
                style: WaveType.meta.copyWith(color: waveAccent(context)),
              ),
              const SizedBox(height: 8),
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
                    onPressed: _busy ? null : () => _saveCookie(_cookie.text),
                    child: Text(strings('spotifyPasteHint')),
                  ),
                  WaveButton(
                    onPressed: _busy ? null : _browser,
                    child: Text(strings('spotifyBrowser')),
                  ),
                  if (_connected)
                    WaveButton(
                      onPressed: _busy ? null : _disconnect,
                      child: Text(strings('spotifyDisconnect')),
                    ),
                  if (_connected) ...[
                    WaveButton(
                      onPressed: _busy ? null : () => _import(false),
                      child: Text(strings('spotifyImport')),
                    ),
                    WaveButton(
                      onPressed: _busy ? null : () => _import(true),
                      child: Text(strings('spotifyLiked')),
                    ),
                  ],
                ],
              ),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _status,
                  style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SettingsTarget(
          id: 'integrations.spotify.canvas',
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(strings('spotifyCanvas'), style: WaveType.trackTitle),
                    Text(
                      strings('spotifyCanvasHint'),
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
              ToggleSwitch(
                checked: canvas,
                onChanged: (value) {
                  widget.onUpdate((p) => p.setSpotifyCanvasEnabled(value));
                  ref.invalidate(canvasClipProvider);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SettingsTarget(
          id: 'integrations.jam',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(strings('jamServer'), style: WaveType.sectionTitle),
              const SizedBox(height: 6),
              TextBox(
                controller: _jam,
                placeholder: 'wss://jam.clashprojects.qd.je/ws',
                decoration: waveInputDecoration(),
                onSubmitted: (value) =>
                    widget.onUpdate((p) => p.setJamServerUrl(value)),
              ),
              const SizedBox(height: 8),
              WaveButton(
                onPressed: () =>
                    widget.onUpdate((p) => p.setJamServerUrl(_jam.text)),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
