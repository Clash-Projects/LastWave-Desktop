import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/jam/jam_client.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';
import '../theme/tokens.dart';

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
  late final TextEditingController _server;
  final _chatFocus = FocusNode();
  final _chatScroll = ScrollController();
  bool _collaborative = true;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: ref.read(prefsProvider).jamDisplayName,
    );
    _server = TextEditingController(
      text: ref.read(prefsProvider).jamServerUrl,
    );
    _code = TextEditingController(text: widget.initialCode ?? '');
    _chat = TextEditingController();
  }

  @override
  void didUpdateWidget(WaveJamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final code = widget.initialCode;
    if (code != null && code != oldWidget.initialCode) _code.text = code;
  }

  void _send() {
    ref.read(jamControllerProvider.notifier).sendChat(_chat.text);
    _chat.clear();
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
    await Clipboard.setData(ClipboardData(
      text: 'Join my LastWave Jam. Room code: $code\n'
          'lastwave://jam?code=$code',
    ));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _chat.dispose();
    _server.dispose();
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
                    const SizedBox(height: 14),
                    _Label('Server'),
                    const SizedBox(height: 6),
                    TextBox(
                      controller: _server,
                      placeholder: 'wss://jam.clashprojects.qd.je/ws',
                      decoration: waveInputDecoration(),
                      onSubmitted: (_) => ref
                          .read(prefsProvider)
                          .setJamServerUrl(_server.text),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: WaveButton(
                        onPressed: () => ref
                            .read(prefsProvider)
                            .setJamServerUrl(_server.text),
                        child: const Text('Save server'),
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
    return LayoutBuilder(builder: (context, box) {
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
              _Label('Room code'),
              const SizedBox(height: 6),
              SelectableText(
                jam.roomCode,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _Pill(label: jam.isHost ? 'Host' : 'Guest'),
                  _Pill(
                    label: jam.roomMode == jamModeHostOnly
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
                      size: 56,
                    ),
                    const SizedBox(width: 12),
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
                      if (person.isHost) const _Pill(label: 'Host'),
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
                      );
                    },
                  ),
          ),
          Container(height: 1, color: waveDivider(context)),
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
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: waveSurface(context),
          borderRadius: BorderRadius.circular(WaveRadius.artwork),
          border: Border.all(color: waveDivider(context)),
        ),
        child: child,
      );
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
  const _Bubble({
    required this.line,
    required this.mine,
    required this.showName,
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: mine
                    ? accent.withValues(alpha: 0.18)
                    : waveSurfaceRaised(context),
                borderRadius: BorderRadius.circular(WaveRadius.menu),
              ),
              child: SelectableText(line.text, style: WaveType.body),
            ),
          ),
        ],
      ),
    );
  }
}
