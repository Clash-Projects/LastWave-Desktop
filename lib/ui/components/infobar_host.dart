import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/network_monitor.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/lastfm/auth_repository.dart';
import '../theme/tokens.dart';

/// Global Fluent InfoBar host — non-blocking feedback docked above content.
///
/// Shows (highest priority first):
/// - offline network
/// - Last.fm session expired
/// - latest download done/error
///
/// Dismissible per-bar, auto-collapses when clear. Rendered by [WaveShell]
/// directly under the title bar so it never blocks playback.
class WaveInfoBarHost extends ConsumerStatefulWidget {
  const WaveInfoBarHost({super.key});
  @override
  ConsumerState<WaveInfoBarHost> createState() => _WaveInfoBarHostState();
}

class _WaveInfoBarHostState extends ConsumerState<WaveInfoBarHost> {
  bool _dismissedOffline = false;
  bool _dismissedAuth = false;
  String? _dismissedDownloadKey;

  @override
  Widget build(BuildContext context) {
    final online = ref.watch(networkMonitorProvider);
    final auth = ref.watch(authRepositoryProvider);
    final downloads = ref.watch(downloadManagerProvider);

    final bars = <Widget>[];
    if (!online && !_dismissedOffline) {
      bars.add(InfoBar(
        title: const Text('You are offline'),
        content: const Text('Charts and streaming may be unavailable.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        onClose: () => setState(() => _dismissedOffline = true),
      ));
    }
    if (auth.status != AuthStatus.signedIn && !_dismissedAuth) {
      bars.add(InfoBar(
        title: const Text('Last.fm disconnected'),
        content: const Text('Connect to keep scrobbling and picks.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        action: HyperlinkButton(
          onPressed: () => context.go('/welcome'),
          child: const Text('Connect'),
        ),
        onClose: () => setState(() => _dismissedAuth = true),
      ));
    }
    DownloadEntry? latest;
    for (final d in downloads) {
      if (d.status == DownloadStatus.done ||
          d.status == DownloadStatus.error) {
        latest = d;
      }
    }
    if (latest != null && _dismissedDownloadKey != latest.key) {
      final entry = latest;
      bars.add(InfoBar(
        title: Text(entry.status == DownloadStatus.done
            ? 'Download complete'
            : 'Download failed'),
        content: Text('${entry.title} — ${entry.artist}'),
        severity: entry.status == DownloadStatus.done
            ? InfoBarSeverity.success
            : InfoBarSeverity.error,
        isLong: false,
        action: HyperlinkButton(
          onPressed: () => context.go('/downloads'),
          child: const Text('Open'),
        ),
        onClose: () =>
            setState(() => _dismissedDownloadKey = entry.key),
      ));
    }
    if (bars.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: waveDivider(context)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: WaveDensity.contentMax),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < bars.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              bars[i],
            ],
          ],
        ),
      ),
    );
  }
}
