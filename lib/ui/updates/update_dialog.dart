import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_info.dart';
import '../../core/storage/prefs.dart';
import '../../features/updates/update_service.dart';
import '../components/buttons.dart';
import '../components/select.dart';
import '../theme/tokens.dart';

/// Shows the in-app GitHub update dialog with full changelogs.
Future<bool?> showUpdateDialog(
  BuildContext context,
  AppUpdateInfo update, {
  bool isManualCheck = false,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => UpdateDialog(
      update: update,
      isManualCheck: isManualCheck,
    ),
  );
}

class UpdateDialog extends ConsumerStatefulWidget {
  final AppUpdateInfo update;
  final bool isManualCheck;

  const UpdateDialog({
    super.key,
    required this.update,
    this.isManualCheck = false,
  });

  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  bool _dontShowAgain = false;
  bool _isDownloading = false;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _errorMessage;
  CancelToken? _cancelToken;
  AppReleaseAsset? _selectedAsset;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(prefsProvider);
    _dontShowAgain = prefs.ignoredUpdateVersion == widget.update.version;
    _selectedAsset = widget.update.findBestAsset();
  }

  @override
  void dispose() {
    _cancelToken?.cancel('Dialog dismissed');
    super.dispose();
  }

  Future<void> _openReleaseUrl() async {
    final uri = Uri.tryParse(widget.update.htmlUrl);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  String _getActionTitle() {
    if (_selectedAsset == null) return 'Update Now';
    final name = _selectedAsset!.name.toLowerCase();
    if (name.endsWith('.exe')) return 'Install Update';
    if (name.endsWith('.appimage')) return 'Update AppImage';
    if (name.endsWith('.deb') || name.endsWith('.rpm')) return 'Download Package';
    if (name.endsWith('.zip')) return 'Download Portable';
    return 'Update Now';
  }

  Future<void> _startUpdate() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _progress = 0.0;
      _receivedBytes = 0;
      _totalBytes = 0;
      _cancelToken = CancelToken();
    });

    try {
      final service = ref.read(updateServiceProvider);
      await service.downloadAndInstall(
        update: widget.update,
        targetAsset: _selectedAsset,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
            if (total > 0) {
              _progress = received / total;
            }
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      if (_cancelToken?.isCancelled ?? false) {
        setState(() {
          _isDownloading = false;
          _cancelToken = null;
        });
        return;
      }
      setState(() {
        _isDownloading = false;
        _errorMessage = 'Download failed: $e';
        _cancelToken = null;
      });
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('Cancelled by user');
    setState(() {
      _isDownloading = false;
      _cancelToken = null;
    });
  }

  Future<void> _onDecline() async {
    final prefs = ref.read(prefsProvider);
    if (_dontShowAgain) {
      await prefs.setIgnoredUpdateVersion(widget.update.version);
    } else {
      // If unchecked, clear any previous ignore for this version so it reminds again
      if (prefs.ignoredUpdateVersion == widget.update.version) {
        await prefs.clearIgnoredUpdateVersion();
      }
    }
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double d = bytes.toDouble();
    while (d >= 1024 && i < suffixes.length - 1) {
      d /= 1024;
      i++;
    }
    return '${d.toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final releaseDate = widget.update.publishedAt != null
        ? DateFormat.yMMMMd().format(widget.update.publishedAt!)
        : null;

    return ContentDialog(
      constraints: const BoxConstraints(
        maxWidth: 540,
        maxHeight: 520,
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(WaveRadius.controls),
            ),
            child: Icon(
              FluentIcons.update_restore,
              color: accent,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text('Update Arrived', style: WaveType.sectionTitle),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: WaveColors.success.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(WaveRadius.tiny),
                      ),
                      child: Text(
                        'v${widget.update.version}',
                        style: WaveType.overline.copyWith(
                          color: WaveColors.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Current version: v$appVersion${releaseDate != null ? ' · $releaseDate' : ''}',
                  style: WaveType.meta.copyWith(
                    color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Text(
            widget.update.title.isNotEmpty && widget.update.title != widget.update.tagName
                ? widget.update.title
                : 'Changelog:',
            style: WaveType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: dark ? WaveColors.surface : WaveColors.lightSurface,
                borderRadius: BorderRadius.circular(WaveRadius.controls),
                border: Border.all(
                  color: dark ? WaveColors.outline : WaveColors.lightOutline,
                ),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: _ChangelogRenderer(
                    markdown: widget.update.changelog.isNotEmpty
                        ? widget.update.changelog
                        : 'No detailed release notes provided.',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: WaveColors.danger.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(WaveRadius.tiny),
              ),
              child: Row(
                children: [
                  const Icon(FluentIcons.error_badge, color: WaveColors.danger, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: WaveType.meta.copyWith(color: WaveColors.danger),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_isDownloading) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ProgressBar(value: _progress > 0 ? _progress * 100 : null),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _totalBytes > 0
                          ? 'Downloading: ${(_progress * 100).toStringAsFixed(0)}%'
                          : 'Starting download...',
                      style: WaveType.meta,
                    ),
                    if (_totalBytes > 0)
                      Text(
                        '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}',
                        style: WaveType.meta.copyWith(
                          color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ] else ...[
            if (widget.update.assets.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    'Package:',
                    style: WaveType.meta.copyWith(
                      fontWeight: FontWeight.w600,
                      color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: WaveSelect<AppReleaseAsset>(
                      value: _selectedAsset,
                      options: widget.update.assets
                          .map((a) => WaveSelectOption(
                                value: a,
                                label: '${a.name} (${_formatBytes(a.size)})',
                              ))
                          .toList(),
                      onChanged: (asset) {
                        setState(() => _selectedAsset = asset);
                      },
                      expanded: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Checkbox(
              checked: _dontShowAgain,
              content: const Text("Don't show again for this version"),
              onChanged: (v) {
                setState(() => _dontShowAgain = v ?? false);
              },
            ),
          ],
        ],
      ),
      actions: _isDownloading
          ? [
              WaveButton(
                onPressed: _cancelDownload,
                child: const Text('Cancel Download'),
              ),
            ]
          : [
              if (widget.update.htmlUrl.isNotEmpty)
                WaveButton(
                  onPressed: _openReleaseUrl,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.open_in_new_window, size: 13),
                      SizedBox(width: 6),
                      Text('GitHub'),
                    ],
                  ),
                ),
              WaveButton(
                onPressed: _onDecline,
                child: const Text('Remind Me Later'),
              ),
              WaveFilledButton(
                onPressed: _startUpdate,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(FluentIcons.download, size: 14),
                    const SizedBox(width: 6),
                    Text(_getActionTitle()),
                  ],
                ),
              ),
            ],
    );
  }
}

/// Formatter that cleanly displays markdown release notes.
class _ChangelogRenderer extends StatelessWidget {
  final String markdown;

  const _ChangelogRenderer({required this.markdown});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final lines = markdown.split('\n');

    final widgets = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }

      if (line.startsWith('### ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            line.substring(4).replaceAll('**', ''),
            style: WaveType.body.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ));
      } else if (line.startsWith('## ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(
            line.substring(3).replaceAll('**', ''),
            style: WaveType.sectionTitle.copyWith(fontSize: 16),
          ),
        ));
      } else if (line.startsWith('# ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(
            line.substring(2).replaceAll('**', ''),
            style: WaveType.pageTitle.copyWith(fontSize: 18),
          ),
        ));
      } else if (line.startsWith('* ') || line.startsWith('- ')) {
        final content = line.substring(2).trim();
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '• ',
                style: TextStyle(
                  color: waveAccent(context),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: Text(
                  content,
                  style: WaveType.body.copyWith(
                    color: dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ));
      } else {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            line,
            style: WaveType.body.copyWith(
              color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
              height: 1.35,
            ),
          ),
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }
}
