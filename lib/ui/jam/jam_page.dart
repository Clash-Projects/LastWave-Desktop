import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/storage/prefs.dart';
import '../../features/jam/jam_client.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Collaborative listening room. Local playback keeps running if the
/// server cannot be reached; the error is shown here.
class WaveJamPage extends ConsumerStatefulWidget {
  final String? initialCode;
  const WaveJamPage({super.key, this.initialCode});

  @override
  ConsumerState<WaveJamPage> createState() => _WaveJamPageState();
}

class _WaveJamPageState extends ConsumerState<WaveJamPage> {
  late final TextEditingController _name;
  late final TextEditingController _code;
  late final TextEditingController _chat;
  final _chatFocus = FocusNode();
  final _chatScroll = ScrollController();
  bool _collaborative = true;
  bool _copied = false;
  JamChatLine? _replyTo;
  Timer? _noticeTimer;
  Timer? _countsTimer;
  Map<String, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: ref.read(prefsProvider).jamDisplayName,
    );
    _code = TextEditingController(text: widget.initialCode ?? '');
    _chat = TextEditingController();
    _loadCounts();
    _countsTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (ref.read(jamControllerProvider).phase != JamPhase.active) {
        _loadCounts();
      }
    });
  }

  Future<void> _loadCounts() async {
    final counts =
        await ref.read(jamControllerProvider.notifier).fetchRoomCounts();
    if (mounted && counts.isNotEmpty) setState(() => _counts = counts);
  }

  @override
  void didUpdateWidget(WaveJamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final code = widget.initialCode;
    if (code != null && code != oldWidget.initialCode) _code.text = code;
  }

  void _send() {
    ref
        .read(jamControllerProvider.notifier)
        .sendChat(_chat.text, replyToId: _replyTo?.id);
    _chat.clear();
    if (_replyTo != null) setState(() => _replyTo = null);
    // Focus alone is not enough: after a submit the field still looks
    // focused but its keyboard connection is gone (alt-tab restores it).
    // Dropping focus and taking it back on the next frame re-opens it.
    _chatFocus.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chatFocus.requestFocus();
    });
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _copyInvite(String code) async {
    // Just the link: chat apps turn it into a preview card and tapping it
    // opens the installed LastWave.
    await Clipboard.setData(ClipboardData(
      text: ref.read(jamControllerProvider.notifier).inviteLink(code),
    ));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  void _reply(JamChatLine line) {
    setState(() => _replyTo = line);
    _chatFocus.requestFocus();
  }

  /// Clears the server notice once the cooldown has passed (or after a few
  /// seconds for plain messages).
  void _scheduleNoticeClear(JamSnapshot jam) {
    _noticeTimer?.cancel();
    if (jam.notice.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ms = jam.retryAtMs > now ? jam.retryAtMs - now + 500 : 6000;
    _noticeTimer = Timer(Duration(milliseconds: ms), () {
      if (mounted) ref.read(jamControllerProvider.notifier).clearNotice();
    });
  }

  static String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    String two(int v) => v.toString().padLeft(2, '0');
    return '$h:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _countsTimer?.cancel();
    _name.dispose();
    _code.dispose();
    _chat.dispose();
    _chatFocus.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jam = ref.watch(jamControllerProvider);
    ref.listen(
      jamControllerProvider.select((s) => s.chat.length),
      (_, _) => _scrollChatToEnd(),
    );
    ref.listen<JamSnapshot>(
      jamControllerProvider,
      (prev, next) {
        if (prev?.notice != next.notice || prev?.retryAtMs != next.retryAtMs) {
          _scheduleNoticeClear(next);
        }
      },
    );
    final active = jam.phase == JamPhase.active;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Jam', style: WaveType.pageTitle),
              if (active) ...[
                const SizedBox(width: 12),
                _Pill(
                  label: 'Live',
                  color: WaveColors.success,
                  dot: true,
                ),
              ],
              const Spacer(),
              WaveIconButton(
                tooltip: 'Close',
                icon: const Icon(WaveIcons.close, size: 14),
                onPressed: () => context.go('/home'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            active
                ? 'Playback stays in sync with everyone in the room.'
                : 'Listen together. Rooms run on a hosted Clash Projects '
                    'server; if it is unreachable, playback on this device '
                    'keeps going.',
            style: WaveType.body.copyWith(color: waveTextSecondary(context)),
          ),
          const SizedBox(height: 20),
          Expanded(child: active ? _room(context, jam) : _entry(context, jam)),
        ],
      ),
    );
  }

  // ---- Not in a room -------------------------------------------------

  Widget _entry(BuildContext context, JamSnapshot jam) {
    final busy = jam.phase == JamPhase.connecting;
    final controller = ref.read(jamControllerProvider.notifier);
    void remember() =>
        ref.read(prefsProvider).setJamDisplayName(_name.text);
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (jam.phase == JamPhase.error)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: InfoBar(
                    title: Text(
                      jam.error.isEmpty ? 'Connection failed' : jam.error,
                    ),
                    severity: InfoBarSeverity.warning,
                  ),
                ),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Label('Your name'),
                    const SizedBox(height: 6),
                    TextBox(
                      controller: _name,
                      placeholder: 'Listener',
                      decoration: waveInputDecoration(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Always-on rooms', style: WaveType.sectionTitle),
                    const SizedBox(height: 4),
                    Text(
                      'Open all day. The first person in is the admin.',
                      style: WaveType.meta
                          .copyWith(color: waveTextSecondary(context)),
                    ),
                    const SizedBox(height: 12),
                    for (final station in jamStations)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(station.title,
                                      style: WaveType.body.copyWith(
                                          fontWeight: FontWeight.w600)),
                                  Text(
                                    _counts[station.code] == null
                                        ? '${station.blurb} · ${station.code}'
                                        : '${_counts[station.code]} listening · ${station.code}',
                                    style: WaveType.meta.copyWith(
                                        color: waveTextSecondary(context)),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            WaveFilledButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      remember();
                                      controller.joinRoom(
                                          station.code, _name.text);
                                    },
                              child: const Text('Join'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Start a room', style: WaveType.sectionTitle),
                    const SizedBox(height: 4),
                    Text(
                      'You get a code to share with friends.',
                      style: WaveType.meta
                          .copyWith(color: waveTextSecondary(context)),
                    ),
                    const SizedBox(height: 12),
                    ToggleSwitch(
                      checked: _collaborative,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => _collaborative = v),
                      content: Text(
                        _collaborative
                            ? 'Everyone controls playback'
                            : 'Only the host controls playback',
                      ),
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: WaveFilledButton(
                        onPressed: busy
                            ? null
                            : () {
                                remember();
                                controller.createRoom(
                                  _name.text,
                                  collaborative: _collaborative,
                                );
                              },
                        child: Text(busy ? 'Connecting…' : 'Create room'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Join a room', style: WaveType.sectionTitle),
                    const SizedBox(height: 4),
                    Text(
                      'Enter the code a friend sent you.',
                      style: WaveType.meta
                          .copyWith(color: waveTextSecondary(context)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextBox(
                            controller: _code,
                            placeholder: 'ABC123',
                            decoration: waveInputDecoration(),
                            style: const TextStyle(
                              letterSpacing: 3,
                              fontWeight: FontWeight.w600,
                            ),
                            onSubmitted: busy
                                ? null
                                : (_) {
                                    remember();
                                    controller.joinRoom(
                                        _code.text, _name.text);
                                  },
                          ),
                        ),
                        const SizedBox(width: 8),
                        WaveButton(
                          onPressed: busy
                              ? null
                              : () {
                                  remember();
                                  controller.joinRoom(
                                      _code.text, _name.text);
                                },
                          child: const Text('Join'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- In a room -----------------------------------------------------

  Widget _room(BuildContext context, JamSnapshot jam) {
    final info = _roomColumn(context, jam);
    final chat = _chatCard(context, jam);
    final body = LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 860) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              info,
              const SizedBox(height: 14),
              SizedBox(height: 420, child: chat),
            ],
          ),
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 340, child: SingleChildScrollView(child: info)),
          const SizedBox(width: 16),
          Expanded(child: chat),
        ],
      );
    });
    if (jam.notice.isEmpty) return body;
    final limited = jam.retryAtMs > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: InfoBar(
            title: Text(
              limited
                  ? 'One pause or change per minute. '
                      'Try again at ${_clock(jam.retryAtMs)}.'
                  : jam.notice,
            ),
            severity: InfoBarSeverity.warning,
            onClose: ref.read(jamControllerProvider.notifier).clearNotice,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _roomColumn(BuildContext context, JamSnapshot jam) {
    final controller = ref.read(jamControllerProvider.notifier);
    final secondary = waveTextSecondary(context);
    final track = jam.track;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Label(jam.roomName.isEmpty
                  ? 'Room code'
                  : 'Room · ${jam.roomCode}'),
              const SizedBox(height: 8),
              // The code sits in its own tinted tile so it reads at a glance.
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: waveAccent(context).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(WaveRadius.menu),
                  border: Border.all(
                    color: waveAccent(context).withValues(alpha: 0.28),
                    width: 0.8,
                  ),
                ),
                child: SelectableText(
                  jam.roomName.isEmpty ? jam.roomCode : jam.roomName,
                  contextMenuBuilder: TextBox.defaultContextMenuBuilder,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: jam.roomName.isEmpty ? 8 : 1,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _Pill(
                    label: jam.radio
                        ? (jam.isHost ? 'Station admin' : 'Listener')
                        : jam.isMainHost
                            ? 'Host'
                            : jam.isHost
                                ? 'Co-host'
                                : 'Guest',
                  ),
                  if (jam.radio)
                    _Pill(
                      label: 'Live station',
                      color: WaveColors.success,
                      dot: true,
                    )
                  else if (jam.permanent)
                    const _Pill(label: 'Always on'),
                  _Pill(
                    label: jam.radio
                        ? (jam.stationAuto
                            ? 'Auto radio'
                            : 'Admin controls playback')
                        : jam.roomMode == jamModeHostOnly
                            ? 'Host controls playback'
                            : 'Everyone controls playback',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: WaveFilledButton(
                      onPressed: () => _copyInvite(jam.roomCode),
                      child: Text(_copied ? 'Copied' : 'Copy invite'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  WaveButton(
                    onPressed: controller.leave,
                    child: const Text('Leave'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Label('Now playing'),
              const SizedBox(height: 10),
              if (track == null)
                Text(
                  'Nothing yet. Play a song and it plays for everyone.',
                  style: WaveType.meta.copyWith(color: secondary),
                )
              else
                Row(
                  children: [
                    WaveArtwork(
                      url: track.artworkUrl ?? '',
                      title: track.title,
                      artist: track.artist,
                      size: 64,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(color: secondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Label(jam.radio && jam.stationAuto
                  ? 'Up next on the station'
                  : jam.isMainHost
                      ? 'Up next · your queue is shared'
                      : 'Up next · admin queue'),
              const SizedBox(height: 10),
              if (jam.queue.isEmpty)
                Text(
                  'Nothing queued.',
                  style: WaveType.meta.copyWith(color: secondary),
                )
              else ...[
                for (var i = 0; i < jam.queue.length && i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          child: Text('${i + 1}',
                              style: WaveType.meta.copyWith(color: secondary)),
                        ),
                        Expanded(
                          child: Text(
                            jam.queue[i].artist.isEmpty
                                ? jam.queue[i].title
                                : '${jam.queue[i].title} · ${jam.queue[i].artist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.body,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (jam.queue.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('+${jam.queue.length - 5} more',
                        style: WaveType.meta.copyWith(color: secondary)),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Label('Listeners · ${jam.people.length}'),
              const SizedBox(height: 10),
              for (final person in jam.people)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      _Avatar(name: person.name),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          person.userId == jam.userId
                              ? '${person.name} (you)'
                              : person.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.body,
                        ),
                      ),
                      if (person.isHost)
                        _Pill(
                          label: jam.radio
                              ? 'Admin'
                              : person.isCoHost
                                  ? 'Co-host'
                                  : 'Host',
                        ),
                      if (jam.radio &&
                          jam.isMainHost &&
                          person.userId != jam.userId) ...[
                        const SizedBox(width: 8),
                        WaveButton(
                          onPressed: () =>
                              controller.transferAdmin(person.userId),
                          child: const Text('Make admin'),
                        ),
                      ],
                      if (!jam.radio &&
                          jam.isMainHost &&
                          person.userId != jam.userId) ...[
                        const SizedBox(width: 8),
                        if (person.isCoHost)
                          WaveButton(
                            onPressed: () => controller.revokeHost(person.userId),
                            child: const Text('Remove host'),
                          )
                        else if (jam.coHostId.isEmpty)
                          WaveButton(
                            onPressed: () => controller.grantHost(person.userId),
                            child: const Text('Make host'),
                          ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chatCard(BuildContext context, JamSnapshot jam) {
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: _Label('Chat'),
          ),
          Container(height: 1, color: waveDivider(context)),
          Expanded(
            child: jam.chat.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet. Say hi.',
                      style: WaveType.meta
                          .copyWith(color: waveTextTertiary(context)),
                    ),
                  )
                : ListView.builder(
                    controller: _chatScroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: jam.chat.length,
                    itemBuilder: (context, i) {
                      final line = jam.chat[i];
                      final prev = i > 0 ? jam.chat[i - 1] : null;
                      return _Bubble(
                        line: line,
                        mine: line.userId == jam.userId,
                        showName: prev == null || prev.userId != line.userId,
                        onReply: () => _reply(line),
                      );
                    },
                  ),
          ),
          Container(height: 1, color: waveDivider(context)),
          if (_replyTo != null)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              decoration: BoxDecoration(
                color: waveAccent(context).withValues(alpha: 0.08),
                border: Border(
                  left: BorderSide(color: waveAccent(context), width: 3),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Replying to ${_replyTo!.userName}',
                          style: WaveType.meta.copyWith(
                            color: waveAccent(context),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _replyTo!.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta
                              .copyWith(color: waveTextSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                  WaveIconButton(
                    tooltip: 'Cancel reply',
                    icon: const Icon(FluentIcons.chrome_close, size: 11),
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _chat,
                    focusNode: _chatFocus,
                    placeholder: 'Message',
                    decoration: waveInputDecoration(),
                    // onEditingComplete (not onSubmitted) so Enter does not
                    // run the default "unfocus after submit".
                    onEditingComplete: _send,
                  ),
                ),
                const SizedBox(width: 8),
                WaveFilledButton(
                  onPressed: _send,
                  child: const Text('Send'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final base = waveSurface(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              (dark ? Colors.white : Colors.black)
                  .withValues(alpha: dark ? 0.025 : 0.015),
              base,
            ),
            base,
          ],
        ),
        borderRadius: BorderRadius.circular(WaveRadius.floating),
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: child,
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: WaveType.overline.copyWith(color: waveTextTertiary(context)),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final Color? color;
  final bool dot;
  const _Pill({required this.label, this.color, this.dot = false});

  @override
  Widget build(BuildContext context) {
    final tone = color ?? waveTextSecondary(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: WaveType.meta.copyWith(
              color: tone,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  static const size = 30.0;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: waveAccent(context).withValues(alpha: 0.18),
      ),
      child: Text(
        initial.toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final JamChatLine line;
  final bool mine;
  final bool showName;
  final VoidCallback onReply;
  const _Bubble({
    required this.line,
    required this.mine,
    required this.showName,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    return Padding(
      padding: EdgeInsets.only(top: showName ? 10 : 3),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showName && !mine)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 3),
              child: Text(
                line.isHost ? '${line.userName} · host' : line.userName,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mine) _replyButton(),
              Flexible(child: _bubble(context, accent)),
              if (!mine) _replyButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _replyButton() => WaveIconButton(
        tooltip: 'Reply',
        icon: const Icon(FluentIcons.reply, size: 12),
        onPressed: onReply,
      );

  Widget _bubble(BuildContext context, Color accent) {
    final reply = line.replyTo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: mine
                    ? accent.withValues(alpha: 0.18)
                    : waveSurfaceRaised(context),
                // Chat-bubble shape: the corner facing the speaker is tight.
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(WaveRadius.menu + 4),
                  topRight: const Radius.circular(WaveRadius.menu + 4),
                  bottomLeft: Radius.circular(
                      mine ? WaveRadius.menu + 4 : 4),
                  bottomRight: Radius.circular(
                      mine ? 4 : WaveRadius.menu + 4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (reply != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.12),
                        border: Border(
                          left: BorderSide(color: accent, width: 3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            reply.userName,
                            style: WaveType.meta.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            reply.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SelectableText(
                    line.text,
                    style: WaveType.body,
                    contextMenuBuilder: TextBox.defaultContextMenuBuilder,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
