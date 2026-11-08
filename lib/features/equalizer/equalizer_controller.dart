import 'dart:io';

import 'package:flutter/foundation.dart';
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
    try {
      await _playback.setAudioFilter(af);
    } catch (error, stackTrace) {
      // A failed optional DSP update must not crash the player screen.
      // Keep the selected curve in prefs/state so it can be retried later.
      debugPrint('LastWave equalizer update failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static String _formatMpvFilter(EqualizerState s) {
    // iOS uses the lightweight 10-band portion of libmpv's lavfi chain.
    // The optional Studio Clarity crystalizer and limiter are intentionally
    // excluded from the mobile graph: some bundled FFmpeg builds do not ship
    // those filters, and one unavailable filter can reject the entire chain.
    if (Platform.isIOS && !s.enabled) return '';
    if (!Platform.isIOS && !s.isProcessingActive) return '';

    final gains = Platform.isIOS
        ? s.gainsDb
        : s.combinedGainsDb;
    if (gains.every((g) => g.abs() < 0.05)) return '';

    final filters = <String>[];
    // Reserve digital headroom before applying positive band gains.
    var maxBoost = 0.0;
    for (final g in gains) {
      if (g > maxBoost) maxBoost = g;
    }
    final shift = maxBoost > 0.05 ? maxBoost : 0.0;
    for (int i = 0; i < eqBandFreqsHz.length; i++) {
      final freq = eqBandFreqsHz[i];
      final gain = gains[i] - shift;
      if (gain.abs() < 0.05) continue;
      filters.add('equalizer=f=$freq:t=o:w=1:g=${gain.toStringAsFixed(1)}');
    }

    if (Platform.isIOS) {
      // PlaybackService merges this into its libmpv audio-filter graph.
      return 'lavfi=[${filters.join(",")}]';
    }

    if (s.studioClarityEnabled) {
      final exciterTrim = s.clarityPreset.trimsDb.length > 7
          ? s.clarityPreset.trimsDb[7]
          : 0.0;
      final intensity = (1.3 + exciterTrim * 0.15).clamp(0.6, 2.0);
      filters.add('crystalizer=i=${intensity.toStringAsFixed(2)}:c=1');
    }
    filters.add('alimiter=limit=0.98:level=0');
    return 'format=floatp,lavfi=[${filters.join(",")}]';
  }
}
