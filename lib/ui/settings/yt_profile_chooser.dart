import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/innertube/innertube_api.dart';
import '../components/artwork.dart';
import '../theme/tokens.dart';

/// Channel selection result: roster profile email + channel page ID
/// ('' = main channel).
typedef YtSelection = ({String email, String pageId});

/// YouTube identity chooser: one flat list of every known channel
/// across the roster (avatar, name, account line, current badge).
/// Always shown after a capture — even a single row, as an identity
/// double-check before connecting. Null when cancelled.
///
/// Rows seed instantly from the stored roster, then each row
/// live-resolves its identity (sequentially — the API temp-swaps one
/// shared connection, so parallel resolves would corrupt each other)
/// and swaps in fresh name/handle/photo. Stored rows are fossilized
/// too easily (stale jars, old builds) to render as-is.
Future<YtSelection?> showYtProfileChooser({
  required BuildContext context,
  required List<YtProfile> roster,
  required String activeEmail,
  required String activePageId,
  String title = 'Choose channel',
  String hint =
      'Pick the identity to connect. Brand channels share their '
      'Google login — switching never signs anything out.',
}) {
  return showDialog<YtSelection>(
    context: context,
    builder: (_) => _ChooserDialog(
      roster: roster,
      activeEmail: activeEmail,
      activePageId: activePageId,
      title: title,
      hint: hint,
    ),
  );
}

class _LiveRow {
  final String email;
  final String cookies;
  final YtChannel channel;
  final bool current;
  const _LiveRow({
    required this.email,
    required this.cookies,
    required this.channel,
    required this.current,
  });

  _LiveRow withChannel(YtChannel c) => _LiveRow(
        email: email,
        cookies: cookies,
        channel: c,
        current: current,
      );
}

class _ChooserDialog extends ConsumerStatefulWidget {
  final List<YtProfile> roster;
  final String activeEmail;
  final String activePageId;
  final String title;
  final String hint;
  const _ChooserDialog({
    required this.roster,
    required this.activeEmail,
    required this.activePageId,
    required this.title,
    required this.hint,
  });

  @override
  ConsumerState<_ChooserDialog> createState() =>
      _ChooserDialogState();
}

class _ChooserDialogState
    extends ConsumerState<_ChooserDialog> {
  late List<_LiveRow> _rows;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _rows = [
      for (final p in widget.roster)
        for (final c in (p.channels.isEmpty
            ? const [YtChannel()]
            : p.channels))
          _LiveRow(
            email: p.email,
            cookies: p.cookies,
            channel: c,
            current: p.email == widget.activeEmail &&
                c.pageId == widget.activePageId,
          ),
    ];
    _refreshRows();
  }

  Future<void> _refreshRows() async {
    final api = ref.read(innerTubeProvider);
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      if (r.cookies.isEmpty) continue;
      YtAccount? identity;
      try {
        identity = await api.resolveIdentityFor(
          r.cookies,
          pageId: r.channel.pageId,
        );
      } catch (_) {
        identity = null;
      }
      if (!mounted) return;
      if (identity == null || identity.name.isEmpty) {
        continue;
      }
      final liveHandle = identity.handle.isNotEmpty
          ? identity.handle
          : r.channel.handle;
      setState(() {
        _rows[i] = r.withChannel(YtChannel(
          pageId: r.channel.pageId,
          name: identity!.name,
          handle: liveHandle == 'unknown' ? '' : liveHandle,
          photoUrl: identity.photoUrl.isNotEmpty
              ? identity.photoUrl
              : r.channel.photoUrl,
        ));
      });
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 420,
          maxHeight: 380,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.hint,
                style: const TextStyle(fontSize: 12),
              ),
              if (_loading) ...[
                const SizedBox(height: 8),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: ProgressRing(
                        strokeWidth: 2,
                      ),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Refreshing…',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              for (final r in _rows)
                _row(context, r),
            ],
          ),
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Displayable channel handle: must look like one (@-prefixed).
/// Anything else (stale literals, emails in the wrong slot) falls
/// through to the email line instead.
String ytDisplayHandle(YtChannel channel) =>
    channel.handle.startsWith('@') ? channel.handle : '';

/// Displayable email: never the 'unknown' sentinel.
String ytDisplayEmail(String email) =>
    email != 'unknown' ? email : '';

Widget _row(BuildContext dialogContext, _LiveRow r) {
  final handle = ytDisplayHandle(r.channel);
  final mail = ytDisplayEmail(r.email);
  final rawName = r.channel.name.isNotEmpty
      ? r.channel.name
      : handle;
  final name = (rawName.isNotEmpty && rawName != 'unknown')
      ? rawName
      : (mail.isNotEmpty ? mail : 'Channel');
  final idLine = handle.isNotEmpty ? handle : mail;
  final sub = [
    if (r.channel.name.isNotEmpty && idLine.isNotEmpty)
      idLine,
    if (r.channel.isMain) 'Main channel' else 'Brand channel',
    if (r.current) 'Current',
  ].join(' · ');
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Button(
      onPressed: () => Navigator.of(dialogContext).pop((
        email: r.email,
        pageId: r.channel.pageId,
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            if (r.channel.photoUrl.isNotEmpty)
              WaveArtwork.circle(
                url: r.channel.photoUrl,
                size: 36,
                label: name,
                upgrade: false,
              )
            else
              const Icon(FluentIcons.contact, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle,
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                        color: waveTextSecondary(
                            dialogContext)),
                  ),
                ],
              ),
            ),
            if (r.current)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(FluentIcons.check_mark,
                    size: 14),
              ),
          ],
        ),
      ),
    ),
  );
}
