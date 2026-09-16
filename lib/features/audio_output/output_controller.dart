import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';
import 'dac_device.dart';
import 'format_negotiator.dart';
import 'output_path_status.dart';
import 'pcm_format.dart';
import 'wasapi_engine.dart';

class AudioOutputState {
  final List<DacDevice> devices;
  final String selectedId;
  final bool exclusiveRequested;
  final bool bitPerfectRequested;
  final OutputPathStatus path;
  final PcmFormat? lastOpenedFormat;
  final bool probing;

  const AudioOutputState({
    this.devices = const [],
    this.selectedId = '',
    this.exclusiveRequested = false,
    this.bitPerfectRequested = false,
    this.path = const OutputPathStatus(),
    this.lastOpenedFormat,
    this.probing = false,
  });

  DacDevice? get selected {
    if (devices.isEmpty) return null;
    if (selectedId.isEmpty) {
      for (final d in devices) {
        if (d.isDefault) return d;
      }
      return devices.first;
    }
    for (final d in devices) {
      if (d.id == selectedId) return d;
    }
    return null;
  }

  AudioOutputState copyWith({
    List<DacDevice>? devices,
    String? selectedId,
    bool? exclusiveRequested,
    bool? bitPerfectRequested,
    OutputPathStatus? path,
    PcmFormat? lastOpenedFormat,
    bool? probing,
  }) =>
      AudioOutputState(
        devices: devices ?? this.devices,
        selectedId: selectedId ?? this.selectedId,
        exclusiveRequested: exclusiveRequested ?? this.exclusiveRequested,
        bitPerfectRequested: bitPerfectRequested ?? this.bitPerfectRequested,
        path: path ?? this.path,
        lastOpenedFormat: lastOpenedFormat ?? this.lastOpenedFormat,
        probing: probing ?? this.probing,
      );
}

/// Owns WASAPI device selection, exclusive-mode mpv properties, hardware
/// volume, and the bit-perfect status machine. Does not replace media_kit.
class AudioOutputController extends StateNotifier<AudioOutputState> {
  final Ref _ref;
  final WasapiEngine _engine;
  final FormatNegotiator _negotiator;
  StreamSubscription<Map<String, dynamic>>? _hotplug;
  bool _attached = false;
  String? _lastLogged;

  AudioOutputController(this._ref, {WasapiEngine? engine})
      : _engine = engine ?? const WasapiEngine(),
        _negotiator = const FormatNegotiator(),
        super(const AudioOutputState()) {
    final prefs = _ref.read(prefsProvider);
    state = state.copyWith(
      selectedId: prefs.audioDeviceId,
      exclusiveRequested: prefs.wasapiExclusive || prefs.bitPerfect,
      bitPerfectRequested: prefs.wasapiExclusive || prefs.bitPerfect,
    );
  }

  @override
  void dispose() {
    _hotplug?.cancel();
    super.dispose();
  }

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    await refreshDevices();
    _hotplug = _engine.deviceEvents.listen((event) {
      unawaited(_onHotplug(event));
    });
    await applyToPlayer();
    _rebuildPath();
  }

  Future<void> onPlaybackChanged(
      PlayerSnapshot? prev, PlayerSnapshot next) async {
    await _onPlayback(prev, next);
  }

  Future<void> refreshDevices() async {
    state = state.copyWith(probing: true);
    final devices = await _engine.enumerateDevices();
    var selected = state.selectedId;
    if (selected.isNotEmpty &&
        devices.every((d) => d.id != selected) &&
        devices.isNotEmpty) {
      selected = '';
    }
    state = state.copyWith(
      devices: devices,
      selectedId: selected,
      probing: false,
    );
    _rebuildPath();
    _logCaps();
  }

  Future<void> selectDevice(String id) async {
    await _ref.read(prefsProvider).setAudioDeviceId(id);
    state = state.copyWith(selectedId: id);
    wasapiLog('Device: ${state.selected?.name ?? 'System default'}');
    await applyToPlayer();
    _rebuildPath();
  }

  Future<void> setExclusive(bool exclusive) async {
    await _ref.read(prefsProvider).setWasapiExclusive(exclusive);
    await _ref.read(prefsProvider).setBitPerfect(exclusive);
    state = state.copyWith(
      exclusiveRequested: exclusive,
      bitPerfectRequested: exclusive,
    );
    wasapiLog('Exclusive Mode: $exclusive');
    await applyToPlayer();
    _rebuildPath();
  }

  Future<void> setBitPerfect(bool enabled) => setExclusive(enabled);

  void refreshPath() => _rebuildPath();

  Future<void> applyToPlayer() async {
    final playback = _ref.read(playbackServiceProvider.notifier);
    final device = state.selected;
    final exclusive = state.exclusiveRequested;
    final hw = exclusive && (device?.hardwareVolume ?? false);
    final source = _sourceOf(_ref.read(playbackServiceProvider).stream);
    final decision = source == null
        ? null
        : _negotiator.negotiate(
            source: source,
            device: device,
            exclusiveRequested: exclusive,
          );
    await playback.configureWasapi(
      exclusive: exclusive,
      mpvDevice: device?.mpvDeviceName ?? 'auto',
      lockSoftwareVolume: exclusive,
      outputFormat: exclusive ? decision?.output : null,
    );
    if (hw) {
      final vol = _ref.read(playbackServiceProvider).volume;
      await _engine.setHardwareVolume(device!.id, vol);
      wasapiLog('Hardware Volume: TRUE');
    } else {
      wasapiLog('Hardware Volume: FALSE');
    }
  }

  Future<void> setVolume(double volume) async {
    final playback = _ref.read(playbackServiceProvider.notifier);
    final device = state.selected;
    final hw = state.exclusiveRequested && (device?.hardwareVolume ?? false);
    if (hw) {
      await playback.setVolume(volume, software: false);
      await _engine.setHardwareVolume(device!.id, volume);
      return;
    }
    if (state.exclusiveRequested) {
      await playback.setVolume(1.0, software: false);
      _rebuildPath();
      return;
    }
    await playback.setVolume(volume, software: true);
    _rebuildPath();
  }

  Future<void> _onHotplug(Map<String, dynamic> event) async {
    final reason = event['reason']?.toString() ?? '';
    final id = event['id']?.toString() ?? '';
    wasapiLog('Device event: $reason $id');
    final selected = state.selectedId;
    await refreshDevices();
    if (reason == 'removed' && selected.isNotEmpty && selected == id) {
      await _ref.read(playbackServiceProvider.notifier).pause();
      state = state.copyWith(
        path: state.path.copyWith(
          reason: BitPerfectReason.deviceUnavailable,
          error: 'DAC disconnected',
        ),
      );
      return;
    }
    if (reason == 'added' || reason == 'default' || reason == 'state') {
      await applyToPlayer();
    }
  }

  Future<void> _onPlayback(PlayerSnapshot? prev, PlayerSnapshot next) async {
    final prevFmt = _sourceOf(prev?.stream);
    final nextFmt = _sourceOf(next.stream);
    if (nextFmt != null && state.exclusiveRequested) {
      if (prevFmt == null || !prevFmt.matches(nextFmt)) {
        wasapiLog('Format change detected');
        if (prevFmt != null) wasapiLog('Previous: ${prevFmt.label}');
        wasapiLog('Requested: ${nextFmt.label}');
        final device = state.selected;
        if (device != null && device.supports(nextFmt)) {
          wasapiLog('DAC supports requested format');
          wasapiLog('Reinitializing exclusive stream');
        } else {
          wasapiLog('DAC does not list ${nextFmt.label} as exclusive PCM');
        }
        await applyToPlayer();
      }
    }
    if (next.volume != (prev?.volume ?? next.volume)) {
      final device = state.selected;
      if (state.exclusiveRequested && device?.hardwareVolume == true) {
        await _engine.setHardwareVolume(device!.id, next.volume);
      }
    }
    _rebuildPath(snapshot: next);
  }

  PcmFormat? _sourceOf(ResolvedStream? stream) {
    if (stream == null) return null;
    return pcmFromStream(
      bitDepth: stream.bitDepth,
      samplingRateKhz: stream.samplingRateKhz,
    );
  }

  void _rebuildPath({PlayerSnapshot? snapshot}) {
    final PlayerSnapshot snap =
        snapshot ?? _ref.read(playbackServiceProvider);
    final device = state.selected;
    final source = _sourceOf(snap.stream);
    final live = snap.outputFormat;
    final exclusive = state.exclusiveRequested;
    var decision = source == null
        ? null
        : _negotiator.negotiate(
            source: source,
            device: device,
            exclusiveRequested: exclusive,
          );
    if (exclusive && snap.outputIsFloat && source != null) {
      decision = FormatDecision(
        source: source,
        output: live ?? decision?.output,
        nativeMatch: false,
        resampling: true,
        formatConversion: true,
        note: 'Output is float — not bit-perfect',
      );
    } else if (exclusive &&
        live != null &&
        source != null &&
        decision != null &&
        decision.nativeMatch &&
        live.sampleRateHz != source.sampleRateHz) {
      decision = FormatDecision(
        source: source,
        output: live,
        nativeMatch: false,
        resampling: true,
        formatConversion: false,
        note: 'AO sample rate ${live.label} ≠ source ${source.label}',
      );
    }
    final playback = _ref.read(playbackServiceProvider.notifier);
    final hw = exclusive && (device?.hardwareVolume ?? false);
    final softwareVol = !hw && snap.volume < 0.999;
    final exclusiveActive = exclusive &&
        playback.exclusiveApplied &&
        playback.wasapiError == null &&
        (device?.exclusiveSupported ?? false) &&
        (decision?.output != null);
    final reason = _negotiator.evaluate(
      decision: decision ??
          FormatDecision(
            source: source ?? const PcmFormat(sampleRateHz: 44100, bitDepth: 16),
            output: live ?? source,
            nativeMatch: false,
            resampling: true,
            formatConversion: true,
          ),
      exclusiveRequested: exclusive,
      exclusiveActive: exclusiveActive,
      deviceAvailable: device != null || !_engine.isSupported,
      dspActive: false,
      peqActive: false,
      softwareVolume: softwareVol,
      crossfade: _ref.read(prefsProvider).crossfadeEnabled,
      speed: snap.speed,
    );
    // Exclusive DAC format is the negotiated integer PCM — never the
    // decoder's s32/float container that media_kit reports as audio-params.
    final output = exclusive
        ? (decision?.output ?? live ?? source)
        : (live ?? source);
    final path = OutputPathStatus(
      deviceName: device?.displayName ?? 'System default',
      deviceId: device?.id ?? '',
      mode: exclusiveActive
          ? WasapiShareMode.exclusive
          : WasapiShareMode.shared,
      exclusiveRequested: exclusive,
      exclusiveActive: exclusiveActive,
      source: source,
      output: output,
      resampling: decision?.resampling ?? false,
      dspActive: false,
      peqActive: false,
      softwareVolume: softwareVol,
      hardwareVolume: hw,
      crossfade: _ref.read(prefsProvider).crossfadeEnabled,
      speed: snap.speed,
      reason: reason,
      error: playback.wasapiError,
    );
    state = state.copyWith(
      path: path,
      lastOpenedFormat: source ?? state.lastOpenedFormat,
    );
    final line =
        'Device: ${path.deviceName} Exclusive: ${path.exclusiveActive} '
        'Source: ${path.sourceLabel} Output: ${path.outputLabel} '
        'Resampling: ${path.resampling} DSP: ${path.dspActive} '
        'Software Volume: ${path.softwareVolume} Hardware Volume: ${path.hardwareVolume} '
        'Bit-Perfect: ${path.bitPerfect}';
    if (line != _lastLogged) {
      _lastLogged = line;
      wasapiLog(line);
      if (output != null) {
        wasapiLog('New format active: ${output.label}');
      }
    }
  }

  void _logCaps() {
    final device = state.selected;
    if (device == null) return;
    wasapiLog('Device: ${device.displayName}');
    wasapiLog('Exclusive Mode: ${device.exclusiveSupported}');
    wasapiLog('Hardware Volume: ${device.hardwareVolume}');
    for (final line in device.supportedSummary.split('\n')) {
      wasapiLog('PCM $line');
    }
  }
}

final audioOutputProvider =
    StateNotifierProvider<AudioOutputController, AudioOutputState>((ref) {
  final controller = AudioOutputController(ref);
  ref.listen<PlayerSnapshot>(playbackServiceProvider, (prev, next) {
    unawaited(controller.onPlaybackChanged(prev, next));
  });
  return controller;
});
