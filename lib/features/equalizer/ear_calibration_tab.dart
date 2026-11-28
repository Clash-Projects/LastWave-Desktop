import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/components/buttons.dart';
import '../../ui/components/inputs.dart';
import '../../ui/theme/tokens.dart';
import '../player/playback_service.dart';
import 'ear_calibration.dart';
import 'ear_calibration_player.dart';
import 'ear_tone_generator.dart';
import 'equalizer_controller.dart';
import 'equalizer_models.dart';
import 'equalizer_panel.dart';

enum _EarWizardStage {
  setup,
  comfort,
  testing,
  result,
}

/// Interactive "play -> listen -> tell -> auto-profile" calibration tab
/// inside [WaveEqualizerPanel].
class EarCalibrationTab extends ConsumerStatefulWidget {
  final ScrollController scrollController;
  final bool dark;

  const EarCalibrationTab({
    super.key,
    required this.scrollController,
    required this.dark,
  });

  @override
  ConsumerState<EarCalibrationTab> createState() => _EarCalibrationTabState();
}

class _EarCalibrationTabState extends ConsumerState<EarCalibrationTab> {
  final EarCalibrationPlayer _tonePlayer = EarCalibrationPlayer();
  late final TextEditingController _nameController;

  _EarWizardStage _stage = _EarWizardStage.setup;
  EarTestMode _mode = EarTestMode.bothEars;
  CalibrationStrength _strength = CalibrationStrength.balanced;
  EarCalibrationSession? _session;
  EarCalibrationResult? _result;

  bool _pausedMainPlayback = false;
  bool _tonePlaying = false;
  bool _audioBusy = false;
  String? _audioError;
  String? _savedNotice;

  static const double _comfortAttenuationDb = -16.0;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: 'My Ear Profile');
  }

  @override
  void dispose() {
    _nameController.dispose();
    unawaited(_tonePlayer.dispose());
    super.dispose();
  }

  Future<void> _pauseMusicIfNeeded() async {
    try {
      final snap = ref.read(playbackServiceProvider);
      if (snap.isPlaying) {
        await ref.read(playbackServiceProvider.notifier).pause();
        _pausedMainPlayback = true;
      }
    } catch (_) {}
  }

  Future<void> _resumeMusicIfPaused() async {
    if (!_pausedMainPlayback) return;
    _pausedMainPlayback = false;
    try {
      await ref.read(playbackServiceProvider.notifier).playResume();
    } catch (_) {}
  }

  Future<void> _playCurrentCue({
    required int freqHz,
    required double attenuationDb,
    required EarChannel channel,
  }) async {
    if (!mounted) return;
    setState(() {
      _audioBusy = true;
      _audioError = null;
    });
    try {
      await _tonePlayer.playTone(
        freqHz: freqHz,
        attenuationDb: attenuationDb,
        channel: channel,
      );
      if (mounted) {
        setState(() {
          _tonePlaying = true;
          _audioBusy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _tonePlaying = false;
          _audioBusy = false;
          _audioError = 'Could not play calibration tone: $e';
        });
      }
    }
  }

  Future<void> _startCalibration() async {
    await _pauseMusicIfNeeded();
    if (!mounted) return;
    setState(() {
      _savedNotice = null;
      _audioError = null;
      _result = null;
      _session = EarCalibrationSession(mode: _mode);
      _stage = _EarWizardStage.comfort;
    });
    await _playCurrentCue(
      freqHz: 1000,
      attenuationDb: _comfortAttenuationDb,
      channel: EarChannel.both,
    );
  }

  Future<void> _beginFrequencySteps() async {
    final session = _session ?? EarCalibrationSession(mode: _mode);
    setState(() {
      _session = session;
      _stage = _EarWizardStage.testing;
    });
    final step = session.currentStep;
    await _playCurrentCue(
      freqHz: step.freqHz,
      attenuationDb: session.currentAttenuationDb,
      channel: step.channel,
    );
  }

  Future<void> _handleListenerResponse(ListenerResponse response) async {
    final session = _session;
    if (session == null || session.isCompleted) return;

    session.recordResponse(response);
    if (session.isCompleted) {
      await _tonePlayer.stopTone();
      if (!mounted) return;
      final res = session.buildResult(strength: _strength);
      setState(() {
        _tonePlaying = false;
        _result = res;
        _stage = _EarWizardStage.result;
      });
      return;
    }

    final nextStep = session.currentStep;
    setState(() {});
    await _playCurrentCue(
      freqHz: nextStep.freqHz,
      attenuationDb: session.currentAttenuationDb,
      channel: nextStep.channel,
    );
  }

  Future<void> _toggleCuePlayback() async {
    if (_tonePlaying) {
      await _tonePlayer.stopTone();
      if (mounted) setState(() => _tonePlaying = false);
      return;
    }
    if (_stage == _EarWizardStage.comfort) {
      await _playCurrentCue(
        freqHz: 1000,
        attenuationDb: _comfortAttenuationDb,
        channel: EarChannel.both,
      );
    } else if (_stage == _EarWizardStage.testing && _session != null) {
      final step = _session!.currentStep;
      await _playCurrentCue(
        freqHz: step.freqHz,
        attenuationDb: _session!.currentAttenuationDb,
        channel: step.channel,
      );
    }
  }

  Future<void> _cancelCalibration({bool resumeMusic = true}) async {
    await _tonePlayer.stopTone();
    if (resumeMusic) {
      await _resumeMusicIfPaused();
    }
    if (!mounted) return;
    setState(() {
      _tonePlaying = false;
      _audioBusy = false;
      _audioError = null;
      _session = null;
      _result = null;
      _stage = _EarWizardStage.setup;
    });
  }

  void _updateStrength(CalibrationStrength next) {
    final session = _session;
    if (session == null) return;
    setState(() {
      _strength = next;
      _result = session.buildResult(strength: next);
    });
  }

  Future<void> _saveAndApplyResult() async {
    final res = _result;
    if (res == null) return;
    final rawName = _nameController.text.trim();
    final name = rawName.isEmpty ? 'My Ear Profile' : rawName;
    final now = DateTime.now().millisecondsSinceEpoch;
    final profile = SavedEarProfile(
      id: 'ear_$now',
      name: name,
      createdAtMs: now,
      mode: res.mode,
      strength: _strength,
      gainsDb: res.balancedGainsDb,
      leftThresholdsDb: res.leftThresholdsDb,
      rightThresholdsDb: res.rightThresholdsDb,
      summary: res.summary,
    );

    await ref.read(equalizerProvider.notifier).saveAndApplyEarProfile(profile);
    await _resumeMusicIfPaused();
    if (!mounted) return;
    setState(() {
      _savedNotice = 'Saved and applied "$name".';
      _session = null;
      _result = null;
      _stage = _EarWizardStage.setup;
    });
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(equalizerProvider);
    final notifier = ref.read(equalizerProvider.notifier);

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        if (_stage == _EarWizardStage.setup)
          ..._buildSetupView(context, eq, notifier),
        if (_stage == _EarWizardStage.comfort) _buildComfortView(context),
        if (_stage == _EarWizardStage.testing) _buildTestingView(context),
        if (_stage == _EarWizardStage.result) _buildResultView(context),
      ],
    );
  }

  List<Widget> _buildSetupView(
    BuildContext context,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    final dark = widget.dark;
    return [
      _card(
        context,
        highlight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xFFF5A623).withValues(alpha: 0.16),
                  ),
                  child: const Icon(
                    FluentIcons.headset,
                    size: 18,
                    color: Color(0xFFF5A623),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Personal Ear Customizer',
                        style: WaveType.body.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      Text(
                        'Listen to safe test cues and tell what you hear — your EQ builds automatically.',
                        style: WaveType.meta.copyWith(
                          fontSize: 11,
                          color: waveTextSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'CALIBRATION MODE',
              style: WaveType.overline.copyWith(
                color: waveTextSecondary(context),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < EarTestMode.values.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _selectableOption(
                      context,
                      title: EarTestMode.values[i].label,
                      subtitle: EarTestMode.values[i] == EarTestMode.bothEars
                          ? '7 bands · ~45 sec'
                          : '5 bands/ear · L/R check',
                      selected: _mode == EarTestMode.values[i],
                      onTap: () =>
                          setState(() => _mode = EarTestMode.values[i]),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'PROFILE NAME',
              style: WaveType.overline.copyWith(
                color: waveTextSecondary(context),
              ),
            ),
            const SizedBox(height: 6),
            TextBox(
              controller: _nameController,
              decoration: waveInputDecoration(),
              placeholder: 'e.g. My Ear Profile or Headphones',
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: WaveFilledButton(
                onPressed: _startCalibration,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(FluentIcons.play, size: 13),
                    SizedBox(width: 8),
                    Text('Start Listen & Tell Test'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      if (_savedNotice != null) ...[
        const SizedBox(height: 10),
        _infoBanner(
          context,
          icon: FluentIcons.check_mark,
          color: dark ? WaveColors.success : const Color(0xFF107C41),
          text: _savedNotice!,
        ),
      ],
      const SizedBox(height: 14),
      Text(
        'SAVED EAR PROFILES (${eq.savedEarProfiles.length})',
        style: WaveType.overline.copyWith(
          color: waveTextSecondary(context),
        ),
      ),
      const SizedBox(height: 8),
      if (eq.savedEarProfiles.isEmpty)
        _card(
          context,
          child: Text(
            'No custom ear profiles yet. Put on your headphones or use your speakers and run the 1-minute listening test above.',
            style: WaveType.meta.copyWith(
              fontSize: 11.5,
              color: waveTextSecondary(context),
            ),
          ),
        )
      else
        for (final profile in eq.savedEarProfiles) ...[
          _savedProfileCard(context, dark, profile, eq, notifier),
          const SizedBox(height: 8),
        ],
    ];
  }

  Widget _savedProfileCard(
    BuildContext context,
    bool dark,
    SavedEarProfile profile,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    final active = eq.enabled && eq.activeEarProfileId == profile.id;
    return _card(
      context,
      highlight: active,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.body.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    WaveChip(
                      label: profile.strength.label,
                      highlight: active,
                    ),
                  ],
                ),
                if (profile.summary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    profile.summary,
                    style: WaveType.meta.copyWith(
                      fontSize: 10.5,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          WaveButton(
            onPressed: active ? null : () => notifier.applyEarProfile(profile),
            child: Text(active ? 'Active' : 'Apply'),
          ),
          const SizedBox(width: 4),
          LWTooltip(
            message: 'Delete ear profile',
            child: IconButton(
              icon: Icon(
                FluentIcons.delete,
                size: 13,
                color: waveTextSecondary(context),
              ),
              onPressed: () => notifier.deleteEarProfile(profile.id),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComfortView(BuildContext context) {
    return _card(
      context,
      highlight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                FluentIcons.volume2,
                size: 18,
                color: Color(0xFFF5A623),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Step 0 · Comfort Volume Check',
                  style: WaveType.sectionTitle.copyWith(fontSize: 14),
                ),
              ),
              WaveChip(label: _tonePlaying ? 'Playing 1 kHz' : 'Paused'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'A soft pulsed 1 kHz tone is playing. Adjust your system or headphone volume to a comfortable, quiet listening level — then keep that volume fixed during the test.',
            style: WaveType.meta.copyWith(
              fontSize: 11.5,
              color: waveTextSecondary(context),
              height: 1.45,
            ),
          ),
          if (_pausedMainPlayback) ...[
            const SizedBox(height: 8),
            _infoBanner(
              context,
              icon: FluentIcons.info,
              color: waveTextSecondary(context),
              text: 'Music playback was paused while calibrating.',
            ),
          ],
          if (_audioError != null) ...[
            const SizedBox(height: 8),
            _infoBanner(
              context,
              icon: FluentIcons.warning,
              color: widget.dark ? WaveColors.danger : const Color(0xFFC42B1C),
              text: _audioError!,
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              WaveButton(
                onPressed: _audioBusy ? null : _toggleCuePlayback,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _tonePlaying ? FluentIcons.pause : FluentIcons.play,
                      size: 12,
                    ),
                    const SizedBox(width: 6),
                    Text(_tonePlaying ? 'Pause Cue' : 'Play Cue'),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              WaveButton(
                onPressed: () => _cancelCalibration(),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              WaveFilledButton(
                onPressed: _beginFrequencySteps,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Volume Ready'),
                    SizedBox(width: 6),
                    Icon(FluentIcons.chevron_right, size: 12),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTestingView(BuildContext context) {
    final session = _session!;
    final step = session.currentStep;
    final dark = widget.dark;
    final roundedAtten = session.currentAttenuationDb.round();
    final attenText = '${roundedAtten == 0 ? 0 : roundedAtten} dB';

    return _card(
      context,
      highlight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              WaveChip(label: step.channelLabel, highlight: true),
              const SizedBox(width: 8),
              Text(
                'Step ${session.stepIndex + 1} of ${session.totalSteps}',
                style: WaveType.meta.copyWith(
                  fontSize: 11,
                  color: waveTextSecondary(context),
                ),
              ),
              const Spacer(),
              Text(
                'Probe $attenText',
                style: WaveType.meta.copyWith(
                  fontSize: 11,
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Linear progress rail
          Container(
            height: 5,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(WaveRadius.tiny),
              color: (dark ? Colors.white : Colors.black)
                  .withValues(alpha: 0.10),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ((session.stepIndex + 0.5) / session.totalSteps)
                  .clamp(0.05, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(WaveRadius.tiny),
                  color: const Color(0xFFF5A623),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            step.bandTitle,
            style: WaveType.sectionTitle.copyWith(fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            'Listen to the pulsed tone. Tell us how clearly you hear it right now:',
            style: WaveType.meta.copyWith(
              fontSize: 11.5,
              color: waveTextSecondary(context),
            ),
          ),
          if (_audioError != null) ...[
            const SizedBox(height: 8),
            _infoBanner(
              context,
              icon: FluentIcons.warning,
              color: widget.dark ? WaveColors.danger : const Color(0xFFC42B1C),
              text: _audioError!,
            ),
          ],
          const SizedBox(height: 14),
          // Primary Listen & Tell buttons
          SizedBox(
            width: double.infinity,
            child: WaveFilledButton(
              onPressed: _audioBusy
                  ? null
                  : () => _handleListenerResponse(ListenerResponse.hearClearly),
              child: const Text('Hear Clearly (Make Quieter)'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: WaveButton(
                  onPressed: _audioBusy
                      ? null
                      : () =>
                          _handleListenerResponse(ListenerResponse.barelyHear),
                  child: const Center(child: Text('Barely Hear · Lock')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: WaveButton(
                  onPressed: _audioBusy
                      ? null
                      : () =>
                          _handleListenerResponse(ListenerResponse.cannotHear),
                  child: const Center(child: Text("Can't Hear (Louder)")),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              WaveButton(
                onPressed: _audioBusy ? null : _toggleCuePlayback,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _tonePlaying ? FluentIcons.pause : FluentIcons.refresh,
                      size: 12,
                    ),
                    const SizedBox(width: 6),
                    Text(_tonePlaying ? 'Pause Cue' : 'Replay Cue'),
                  ],
                ),
              ),
              const Spacer(),
              WaveButton(
                onPressed: () => _cancelCalibration(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultView(BuildContext context) {
    final res = _result!;
    final dark = widget.dark;

    return _card(
      context,
      highlight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                FluentIcons.check_mark,
                size: 16,
                color: WaveColors.success,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your Ear Profile Is Ready',
                  style: WaveType.sectionTitle.copyWith(fontSize: 14.5),
                ),
              ),
              WaveChip(label: _strength.label, highlight: true),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            res.summary,
            style: WaveType.meta.copyWith(
              fontSize: 11.5,
              color: waveTextSecondary(context),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 78,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF101010) : const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(WaveRadius.menu),
              border: Border.all(
                color: waveDivider(context).withValues(alpha: dark ? 0.3 : 0.5),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(WaveRadius.menu - 2),
              child: CustomPaint(
                painter: EqCurvePainter(
                  gainsDb: res.balancedGainsDb,
                  active: true,
                  dark: dark,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Band gain summary chips
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < eqBandFreqsHz.length; i++)
                WaveChip(
                  label:
                      '${eqBandLabel(eqBandFreqsHz[i])} ${res.balancedGainsDb[i] >= 0 ? '+' : ''}${res.balancedGainsDb[i].toStringAsFixed(1)}',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'COMPENSATION STRENGTH',
            style: WaveType.overline.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < CalibrationStrength.values.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: _selectableOption(
                    context,
                    title: CalibrationStrength.values[i].label,
                    subtitle:
                        '${(CalibrationStrength.values[i].factor * 100).round()}%',
                    selected: _strength == CalibrationStrength.values[i],
                    onTap: () => _updateStrength(CalibrationStrength.values[i]),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          TextBox(
            controller: _nameController,
            decoration: waveInputDecoration(),
            placeholder: 'Profile name',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              WaveButton(
                onPressed: _startCalibration,
                child: const Text('Recalibrate'),
              ),
              const SizedBox(width: 8),
              WaveButton(
                onPressed: () => _cancelCalibration(),
                child: const Text('Discard'),
              ),
              const Spacer(),
              WaveFilledButton(
                onPressed: _saveAndApplyResult,
                child: const Text('Save & Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required Widget child,
    bool highlight = false,
  }) {
    final dark = widget.dark;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WaveRadius.menu),
        color: dark ? waveSurfaceRaised(context) : waveSurfaceOverlay(context),
        border: Border.all(
          color: highlight
              ? (dark
                  ? const Color(0xFF8A6D3B).withValues(alpha: 0.75)
                  : const Color(0xFFE5B760))
              : waveDivider(context).withValues(alpha: dark ? 0.3 : 0.5),
          width: highlight ? 1.25 : 1.0,
        ),
      ),
      child: child,
    );
  }

  Widget _selectableOption(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final dark = widget.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: waveMotion(context, WaveMotion.fast),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(WaveRadius.controls),
          color: selected
              ? (dark ? const Color(0xFF2B2418) : const Color(0xFFFFF3D6))
              : (dark
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.black.withValues(alpha: 0.03)),
          border: Border.all(
            color: selected
                ? const Color(0xFFE5B760)
                : waveDivider(context).withValues(alpha: dark ? 0.25 : 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.label.copyWith(
                fontSize: 11,
                color: selected
                    ? (dark ? Colors.white : const Color(0xFF5A3E00))
                    : waveTextPrimary(context),
              ),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                fontSize: 10,
                color: waveTextSecondary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoBanner(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WaveRadius.tiny),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: WaveType.meta.copyWith(fontSize: 10.5, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
