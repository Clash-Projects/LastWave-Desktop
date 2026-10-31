import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/jam/jam_client.dart';
import '../../l10n/app_language.dart';
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
  bool _collaborative = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: ref.read(prefsProvider).jamDisplayName,
    );
    _code = TextEditingController(text: widget.initialCode ?? '');
    _chat = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(shellStringsProvider);
    final jam = ref.watch(jamControllerProvider);
    final controller = ref.read(jamControllerProvider.notifier);
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      children: [
        Text(strings('jam'), style: WaveType.pageTitle),
        const SizedBox(height: 6),
        Text(
          'Listen together. If the server is unreachable, playback on this device keeps going.',
          style: WaveType.body.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 16),
        if (jam.phase == JamPhase.error)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              jam.error.isEmpty ? 'Connection failed' : jam.error,
              style: WaveType.body.copyWith(color: waveAccent(context)),
            ),
          ),
        if (jam.phase != JamPhase.active) ...[
          Text(strings('jamName'), style: WaveType.sectionTitle),
          const SizedBox(height: 6),
          TextBox(
            controller: _name,
            placeholder: 'Listener',
            decoration: waveInputDecoration(),
          ),
          const SizedBox(height: 12),
          ToggleSwitch(
            checked: _collaborative,
            onChanged: jam.phase == JamPhase.connecting
                ? null
                : (value) => setState(() => _collaborative = value),
            content: Text(
              _collaborative ? strings('jamCollab') : strings('jamHost'),
            ),
          ),
          const SizedBox(height: 12),
          Text(strings('jamCode'), style: WaveType.sectionTitle),
          const SizedBox(height: 6),
          TextBox(
            controller: _code,
            placeholder: 'ABC123',
            decoration: waveInputDecoration(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              WaveFilledButton(
                onPressed: jam.phase == JamPhase.connecting
                    ? null
                    : () {
                        ref
                            .read(prefsProvider)
                            .setJamDisplayName(_name.text);
                        controller.createRoom(
                          _name.text,
                          collaborative: _collaborative,
                        );
                      },
                child: Text(strings('jamCreate')),
              ),
              WaveButton(
                onPressed: jam.phase == JamPhase.connecting
                    ? null
                    : () {
                        ref
                            .read(prefsProvider)
                            .setJamDisplayName(_name.text);
                        controller.joinRoom(_code.text, _name.text);
                      },
                child: Text(strings('jamJoin')),
              ),
            ],
          ),
        ] else ...[
          Text(
            '${jam.roomCode} · ${jam.isHost ? strings('jamHost') : strings('participants')}',
            style: WaveType.sectionTitle,
          ),
          const SizedBox(height: 6),
          Text(
            jam.roomMode == jamModeHostOnly
                ? strings('jamHost')
                : strings('jamCollab'),
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
          if (jam.track != null) ...[
            const SizedBox(height: 8),
            Text(
              '${jam.track!.title} — ${jam.track!.artist}',
              style: WaveType.trackTitle,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${strings('jamInvite')}: lastwave://jam?code=${jam.roomCode}',
            style: WaveType.meta,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WaveButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(
                    text:
                        'Join my LastWave Jam. Room code: ${jam.roomCode}\nlastwave://jam?code=${jam.roomCode}',
                  ));
                },
                child: Text(strings('copy')),
              ),
              if (jam.isHost)
                WaveButton(
                  onPressed: () => controller.changeMode(
                    jam.roomMode == jamModeHostOnly
                        ? jamModeCollaborative
                        : jamModeHostOnly,
                  ),
                  child: Text(
                    jam.roomMode == jamModeHostOnly
                        ? strings('jamCollab')
                        : strings('jamHost'),
                  ),
                ),
              WaveButton(
                onPressed: controller.leave,
                child: Text(strings('jamLeave')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(strings('participants'), style: WaveType.sectionTitle),
          for (final person in jam.people)
            Text(
              person.isHost ? '${person.name} · host' : person.name,
              style: WaveType.body,
            ),
          const SizedBox(height: 16),
          Text(strings('jamChat'), style: WaveType.sectionTitle),
          const SizedBox(height: 6),
          for (final line in jam.chat)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${line.userName}: ${line.text}'),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextBox(
                  controller: _chat,
                  placeholder: strings('jamChat'),
                  decoration: waveInputDecoration(),
                  onSubmitted: (value) {
                    controller.sendChat(value);
                    _chat.clear();
                  },
                ),
              ),
              const SizedBox(width: 8),
              WaveFilledButton(
                onPressed: () {
                  controller.sendChat(_chat.text);
                  _chat.clear();
                },
                child: Text(strings('jamSend')),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
