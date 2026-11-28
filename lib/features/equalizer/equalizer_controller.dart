import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import 'ear_calibration.dart';
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
  final Future<void> Function(String af) _setAudioFilter;

  EqualizerNotifier(this._prefs, PlaybackService playback)
      : _setAudioFilter = playback.setAudioFilter,
        super(const EqualizerState()) {
    _loadFromPrefs();
  }

  /// Lightweight constructor for unit tests that verifies `Prefs` persistence
  /// and emitted `libmpv` filter graphs without spawning a live player.
  EqualizerNotifier.forTesting(
    this._prefs, {
    Future<void> Function(String af)? onAudioFilter,
  })  : _setAudioFilter = onAudioFilter ?? ((_) async {}),
        super(const EqualizerState()) {
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

    final savedEarProfiles =
        SavedEarProfile.decodeList(_prefs.customEqProfilesJson);
    final storedProfileId = _prefs.activeEarProfileId;
    final activeEarProfileId =
        savedEarProfiles.any((p) => p.id == storedProfileId)
            ? storedProfileId
            : null;

    state = EqualizerState(
      enabled: enabled,
      presetName: presetName,
      gainsDb: gains,
      studioClarityEnabled: studioClarityEnabled,
      clarityPresetKey: clarityPresetKey,
      savedEarProfiles: savedEarProfiles,
      activeEarProfileId: activeEarProfileId,
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
      clearActiveEarProfile: true,
    );
    await _prefs.setEqualizerEnabled(true);
    await _prefs.setEqualizerPreset(preset.name);
    await _prefs.setEqualizerGains(state.gainsDb.join(','));
    await _prefs.setActiveEarProfileId('');
    await _applyToPlayer();
  }

  /// Saves a calibrated listener ear profile and applies its 10-band curve.
  Future<void> saveAndApplyEarProfile(SavedEarProfile profile) async {
    final nextProfiles = [
      profile,
      for (final existing in state.savedEarProfiles)
        if (existing.id != profile.id) existing,
    ];
    final clampedGains = profile.gainsDb
        .map((g) => double.parse(
            g.clamp(-eqMaxGainDb, eqMaxGainDb).toStringAsFixed(1)))
        .toList(growable: false);

    state = state.copyWith(
      enabled: true,
      presetName: profile.name,
      gainsDb: clampedGains,
      savedEarProfiles: List<SavedEarProfile>.unmodifiable(nextProfiles),
      activeEarProfileId: profile.id,
    );

    await _prefs.setCustomEqProfilesJson(
      SavedEarProfile.encodeList(nextProfiles),
    );
    await _prefs.setEqualizerEnabled(true);
    await _prefs.setEqualizerPreset(profile.name);
    await _prefs.setEqualizerGains(clampedGains.join(','));
    await _prefs.setActiveEarProfileId(profile.id);
    await _applyToPlayer();
  }

  /// Applies an already saved listener ear profile.
  Future<void> applyEarProfile(SavedEarProfile profile) async {
    final clampedGains = profile.gainsDb
        .map((g) => double.parse(
            g.clamp(-eqMaxGainDb, eqMaxGainDb).toStringAsFixed(1)))
        .toList(growable: false);
    state = state.copyWith(
      enabled: true,
      presetName: profile.name,
      gainsDb: clampedGains,
      activeEarProfileId: profile.id,
    );
    await _prefs.setEqualizerEnabled(true);
    await _prefs.setEqualizerPreset(profile.name);
    await _prefs.setEqualizerGains(clampedGains.join(','));
    await _prefs.setActiveEarProfileId(profile.id);
    await _applyToPlayer();
  }

  /// Removes a saved ear profile. If currently active, keeps the curve as
  /// `Custom` without interrupting playback.
  Future<void> deleteEarProfile(String id) async {
    final nextProfiles = [
      for (final existing in state.savedEarProfiles)
        if (existing.id != id) existing,
    ];
    final wasActive = state.activeEarProfileId == id;
    state = state.copyWith(
      savedEarProfiles: List<SavedEarProfile>.unmodifiable(nextProfiles),
      presetName: wasActive ? EqualizerPresets.customName : state.presetName,
      clearActiveEarProfile: wasActive,
    );
    await _prefs.setCustomEqProfilesJson(
      SavedEarProfile.encodeList(nextProfiles),
    );
    if (wasActive) {
      await _prefs.setEqualizerPreset(EqualizerPresets.customName);
      await _prefs.setActiveEarProfileId('');
    }
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
      clearActiveEarProfile: true,
    );

    await _prefs.setEqualizerEnabled(true);
    await _prefs.setEqualizerPreset(EqualizerPresets.customName);
    await _prefs.setEqualizerGains(nextGains.join(','));
    await _prefs.setActiveEarProfileId('');
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
    await _setAudioFilter(af);
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
    return 'format=floatp,lavfi=[${filters.join(",")}]';
  }
}
