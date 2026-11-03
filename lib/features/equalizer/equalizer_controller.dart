import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import 'equalizer_models.dart';

/// Provider for the 10-band Equalizer and Studio Master Clarity controller.
final equalizerProvider =
    StateNotifierProvider<EqualizerNotifier, EqualizerState>((ref) {
  final prefs = ref.watch(prefsProvider);
  final playback = ref.watch(playbackServiceProvider.notifier);
  return EqualizerNotifier(prefs, playback);
});

class EqualizerNotifier extends StateNotifier<EqualizerState> {
  final Prefs _prefs;
  final PlaybackService _playback;

  EqualizerNotifier(this._prefs, this._playback)
      : super(const EqualizerState()) {
    _loadFromPrefs();
  }

  void _loadFromPrefs() {
    final enabled = _prefs.equalizerEnabled;
    final presetName = _prefs.equalizerPreset;
    final studioClarityEnabled = _prefs.studioClarityEnabled;
    final clarityPresetKey = _prefs.studioClarityPreset;

    List<double> gains = EqualizerPresets.flat.gainsDb;
    final storedGainsRaw = _prefs.equalizerGains;
    if (storedGainsRaw.isNotEmpty) {
      final parsed = storedGainsRaw
          .split(',')
          .map((s) => double.tryParse(s.trim()))
          .whereType<double>()
          .toList();
      if (parsed.length == eqBandFreqsHz.length) {
        gains = parsed.map((g) => g.clamp(-eqMaxGainDb, eqMaxGainDb)).toList();
      }
    } else {
      final found = EqualizerPresets.byName(presetName);
      if (found != null) {
        gains = found.gainsDb;
      }
    }

    state = EqualizerState(
      enabled: enabled,
      presetName: presetName,
      gainsDb: gains,
      studioClarityEnabled: studioClarityEnabled,
      clarityPresetKey: clarityPresetKey,
    );

    _applyToPlayer();
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _prefs.setEqualizerEnabled(enabled);
    await _applyToPlayer();
  }

  Future<void> toggleEnabled() async {
    await setEnabled(!state.enabled);
  }

  Future<void> applyPreset(EqPreset preset) async {
    state = state.copyWith(
      enabled: true,
      presetName: preset.name,
      gainsDb: List.of(preset.gainsDb),
    );
    await _prefs.setEqualizerEnabled(true);
    await _prefs.setEqualizerPreset(preset.name);
    await _prefs.setEqualizerGains(state.gainsDb.join(','));
    await _applyToPlayer();
  }

  Future<void> setBandGain(int bandIndex, double gainDb) async {
    if (bandIndex < 0 || bandIndex >= eqBandFreqsHz.length) return;
    final clamped = gainDb.clamp(-eqMaxGainDb, eqMaxGainDb);
    final nextGains = List<double>.from(state.gainsDb);
    nextGains[bandIndex] = double.parse(clamped.toStringAsFixed(1));

    state = state.copyWith(
      enabled: true,
      presetName: EqualizerPresets.customName,
      gainsDb: nextGains,
    );

    await _prefs.setEqualizerEnabled(true);
    await _prefs.setEqualizerPreset(EqualizerPresets.customName);
    await _prefs.setEqualizerGains(nextGains.join(','));
    await _applyToPlayer();
  }

  Future<void> setStudioClarityEnabled(bool enabled) async {
    state = state.copyWith(studioClarityEnabled: enabled);
    await _prefs.setStudioClarityEnabled(enabled);
    await _applyToPlayer();
  }

  Future<void> toggleStudioClarity() async {
    await setStudioClarityEnabled(!state.studioClarityEnabled);
  }

  Future<void> setClarityPreset(String key) async {
    state = state.copyWith(
      clarityPresetKey: key,
      studioClarityEnabled: true,
    );
    await _prefs.setStudioClarityPreset(key);
    await _prefs.setStudioClarityEnabled(true);
    await _applyToPlayer();
  }

  Future<void> setClarityTarget(ClarityPreset target) async {
    await setClarityPreset(target.key);
  }

  Future<void> setPreset(String presetName) async {
    final preset = EqualizerPresets.byName(presetName);
    if (preset != null) {
      await applyPreset(preset);
    }
  }

  Future<void> reset() async {
    await applyPreset(EqualizerPresets.flat);
  }

  Future<void> _applyToPlayer() async {
    final af = _formatMpvFilter(state);
    await _playback.setAudioFilter(af);
  }

  static String _formatMpvFilter(EqualizerState s) {
    if (!s.isProcessingActive) return '';
    final gains = s.combinedGainsDb;
    if (gains.every((g) => g.abs() < 0.05)) return '';

    final filters = <String>[];
    // Auto pre-amp: pull the whole signal down by the largest boost so the
    // EQ can never push peaks past full scale (the old chain clipped on
    // loud masters, which is what made boosted presets sound harsh).
    var maxBoost = 0.0;
    for (final g in gains) {
      if (g > maxBoost) maxBoost = g;
    }
    // Pre-amp WITHOUT the `volume` filter: the libmpv bundled on some
    // builds ships an FFmpeg without it, and one unknown filter fails the
    // whole graph (no audio at all). Shifting every band down by the
    // largest boost gives the same headroom using `equalizer` alone.
    final shift = maxBoost > 0.05 ? maxBoost : 0.0;
    for (int i = 0; i < eqBandFreqsHz.length; i++) {
      final freq = eqBandFreqsHz[i];
      final gain = gains[i] - shift;
      if (gain.abs() < 0.05) continue; // skip flat bands
      filters.add('equalizer=f=$freq:t=o:w=1:g=${gain.toStringAsFixed(1)}');
    }
    // Studio Master Clarity: a touch of transient sharpening on top of the
    // curve, scaled by the output target (gentler for DACs / headphones).
    if (s.studioClarityEnabled) {
      final exciterTrim = s.clarityPreset.trimsDb.length > 7
          ? s.clarityPreset.trimsDb[7]
          : 0.0;
      final intensity = (1.3 + exciterTrim * 0.15).clamp(0.6, 2.0);
      filters.add('crystalizer=i=${intensity.toStringAsFixed(2)}:c=1');
    }
    // Safety net against inter-sample overs; does nothing below 0.98.
    filters.add('alimiter=limit=0.98:level=0');
    return 'format=floatp,lavfi=[${filters.join(",")}]';
  }
}
