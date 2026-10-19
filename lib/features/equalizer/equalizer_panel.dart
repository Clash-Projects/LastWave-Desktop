import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/components/buttons.dart' show LWTooltip;
import '../../ui/theme/tokens.dart';
import 'equalizer_controller.dart';
import 'equalizer_models.dart';

/// Contextual 10-band Equalizer and Studio Master Clarity panel.
///
/// Designed with slide-over drawer styling matching LastWave design tokens.
class WaveEqualizerPanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  const WaveEqualizerPanel({super.key, required this.onClose});

  @override
  ConsumerState<WaveEqualizerPanel> createState() => _WaveEqualizerPanelState();
}

class _WaveEqualizerPanelState extends ConsumerState<WaveEqualizerPanel> {
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final eq = ref.watch(equalizerProvider);
    final notifier = ref.read(equalizerProvider.notifier);

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: dark ? waveSurface(context) : WaveColors.lightSurface,
        border: Border(
          left: BorderSide(
            color: waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          _buildHeader(context, dark, eq, notifier),

          // Content body
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                // Studio Master Clarity card
                _buildStudioClarityCard(context, dark, eq, notifier),
                const SizedBox(height: 14),

                // Frequency response visualizer
                _buildVisualizer(context, dark, eq),
                const SizedBox(height: 14),

                // Presets chip selector
                _buildPresetSelector(context, dark, eq, notifier),
                const SizedBox(height: 16),

                // 10-band slider rack
                _buildSliderRack(context, dark, eq, notifier),
                const SizedBox(height: 16),

                // Bit-perfect status note
                _buildFooterNote(context, dark, eq),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    return Container(
      height: WaveDensity.titleBar + 12,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: waveDivider(context).withValues(alpha: dark ? 0.25 : 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            FluentIcons.equalizer,
            size: 18,
            color: eq.isProcessingActive
                ? WaveColors.defaultAccent
                : waveTextSecondary(context),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Equalizer',
                  style: WaveType.sectionTitle.copyWith(fontSize: 14),
                ),
                Text(
                  eq.isProcessingActive
                      ? (eq.studioClarityEnabled
                          ? 'Studio Master Clarity active'
                          : '${eq.presetName} preset')
                      : 'Bypassed (Bit-Perfect output)',
                  style: WaveType.meta.copyWith(
                    fontSize: 11,
                    color: eq.isProcessingActive
                        ? WaveColors.defaultAccent
                        : waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          // Master switch
          ToggleSwitch(
            checked: eq.enabled,
            onChanged: (val) => notifier.setEnabled(val),
          ),
          const SizedBox(width: 8),
          // Reset button
          LWTooltip(
            message: 'Reset to flat',
            child: IconButton(
              icon: Icon(
                FluentIcons.refresh,
                size: 13,
                color: waveTextSecondary(context),
              ),
              onPressed: notifier.reset,
            ),
          ),
          const SizedBox(width: 4),
          // Close button
          LWTooltip(
            message: 'Close equalizer',
            child: IconButton(
              icon: Icon(
                FluentIcons.chrome_close,
                size: 12,
                color: waveTextSecondary(context),
              ),
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudioClarityCard(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    final active = eq.studioClarityEnabled;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WaveRadius.menu),
        color: active
            ? (dark
                ? const Color(0xFF1F1B14)
                : const Color(0xFFFFF9ED))
            : (dark
                ? waveSurfaceRaised(context)
                : WaveColors.lightOverlay),
        border: Border.all(
          color: active
              ? (dark
                  ? const Color(0xFF8A6D3B).withValues(alpha: 0.6)
                  : const Color(0xFFE5B760))
              : waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
          width: active ? 1.5 : 1,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FluentIcons.favorite_star_fill,
                size: 14,
                color: active
                    ? const Color(0xFFF5A623)
                    : waveTextSecondary(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Studio Master Clarity',
                      style: WaveType.body.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                        color: active
                            ? (dark ? Colors.white : const Color(0xFF5A3E00))
                            : waveTextPrimary(context),
                      ),
                    ),
                    Text(
                      'Audiophile reference curve with targeted acoustic compensation',
                      style: WaveType.meta.copyWith(
                        fontSize: 10.5,
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
              ToggleSwitch(
                checked: active,
                onChanged: (val) => notifier.setStudioClarityEnabled(val),
              ),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: dark
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.8),
                border: Border.all(
                  color: dark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                ),
              ),
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  for (final target in ClarityPresets.all)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => notifier.setClarityPreset(target.key),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: eq.clarityPresetKey == target.key
                                ? (dark
                                    ? const Color(0xFF8A6D3B)
                                    : const Color(0xFFE5B760))
                                : Colors.transparent,
                          ),
                          child: Center(
                            child: Text(
                              target.displayName,
                              style: WaveType.label.copyWith(
                                fontSize: 10.5,
                                fontWeight: eq.clarityPresetKey == target.key
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: eq.clarityPresetKey == target.key
                                    ? (dark ? Colors.white : Colors.black)
                                    : waveTextSecondary(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ClarityPresets.byKey(eq.clarityPresetKey).description,
              style: WaveType.meta.copyWith(
                fontSize: 10.0,
                fontStyle: FontStyle.italic,
                color: waveTextSecondary(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVisualizer(
    BuildContext context,
    bool dark,
    EqualizerState eq,
  ) {
    return Container(
      height: 72,
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
          painter: _EqCurvePainter(
            gainsDb: eq.combinedGainsDb,
            active: eq.isProcessingActive,
            dark: dark,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildPresetSelector(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: EqualizerPresets.all.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final preset = EqualizerPresets.all[index];
          final isSelected = eq.presetName.toLowerCase() == preset.name.toLowerCase();
          final isStudioMaster = preset.name == EqualizerPresets.studioMaster.name;

          return GestureDetector(
            onTap: () => notifier.applyPreset(preset),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: isSelected
                    ? (isStudioMaster
                        ? (dark ? const Color(0xFF8A6D3B) : const Color(0xFFE5B760))
                        : (dark ? Colors.white : Colors.black))
                    : (dark
                        ? waveSurfaceRaised(context)
                        : WaveColors.lightOverlay),
                border: Border.all(
                  color: isSelected
                      ? Colors.transparent
                      : waveDivider(context).withValues(alpha: dark ? 0.3 : 0.5),
                ),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isStudioMaster) ...[
                      Icon(
                        FluentIcons.favorite_star_fill,
                        size: 10,
                        color: isSelected
                            ? (dark ? Colors.white : Colors.black)
                            : const Color(0xFFF5A623),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      preset.name,
                      style: WaveType.label.copyWith(
                        fontSize: 11,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        color: isSelected
                            ? (dark ? Colors.black : Colors.white)
                            : waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSliderRack(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    final gains = eq.gainsDb;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: dark ? waveSurfaceRaised(context) : WaveColors.lightOverlay,
        borderRadius: BorderRadius.circular(WaveRadius.menu),
        border: Border.all(
          color: waveDivider(context).withValues(alpha: dark ? 0.3 : 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (int i = 0; i < eqBandFreqsHz.length; i++)
            _buildBandColumn(
              context,
              dark,
              index: i,
              freqHz: eqBandFreqsHz[i],
              gainDb: gains[i],
              enabled: eq.enabled,
              onChanged: (val) => notifier.setBandGain(i, val),
              onReset: () => notifier.setBandGain(i, 0.0),
            ),
        ],
      ),
    );
  }

  Widget _buildBandColumn(
    BuildContext context,
    bool dark, {
    required int index,
    required int freqHz,
    required double gainDb,
    required bool enabled,
    required ValueChanged<double> onChanged,
    required VoidCallback onReset,
  }) {
    final isNonZero = gainDb.abs() >= 0.1;
    final gainText = gainDb > 0
        ? '+${gainDb.toStringAsFixed(1)}'
        : (gainDb < 0 ? gainDb.toStringAsFixed(1) : '0.0');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Gain display (double-tap to reset)
        GestureDetector(
          onDoubleTap: onReset,
          child: Text(
            gainText,
            style: WaveType.meta.copyWith(
              fontSize: 10,
              fontWeight: isNonZero ? FontWeight.w700 : FontWeight.normal,
              color: isNonZero && enabled
                  ? (gainDb > 0 ? WaveColors.defaultAccent : const Color(0xFF64B5F6))
                  : waveTextSecondary(context).withValues(alpha: 0.7),
            ),
          ),
        ),
        const SizedBox(height: 6),

        // Vertical Slider
        SizedBox(
          height: 140,
          child: Slider(
            vertical: true,
            min: -eqMaxGainDb,
            max: eqMaxGainDb,
            value: gainDb,
            onChanged: enabled ? onChanged : null,
          ),
        ),
        const SizedBox(height: 6),

        // Frequency label
        GestureDetector(
          onDoubleTap: onReset,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: dark
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.black.withValues(alpha: 0.03),
            ),
            child: Text(
              eqBandLabel(freqHz),
              style: WaveType.label.copyWith(
                fontSize: 10,
                color: waveTextSecondary(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFooterNote(
    BuildContext context,
    bool dark,
    EqualizerState eq,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: dark
            ? Colors.black.withValues(alpha: 0.2)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            FluentIcons.info,
            size: 13,
            color: waveTextSecondary(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              eq.isProcessingActive
                  ? '32-bit floating-point IIR filter graph applied in real time via libmpv.'
                  : 'Bypassed: Audio stream flows directly to audio output with bit-perfect integrity.',
              style: WaveType.meta.copyWith(
                fontSize: 10.5,
                color: waveTextSecondary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for smooth frequency response curve with subtle glow fill.
class _EqCurvePainter extends CustomPainter {
  final List<double> gainsDb;
  final bool active;
  final bool dark;

  _EqCurvePainter({
    required this.gainsDb,
    required this.active,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final zeroY = h / 2;

    // Draw baseline (0 dB)
    final gridPaint = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, zeroY), Offset(w, zeroY), gridPaint);

    if (gainsDb.isEmpty) return;

    final n = gainsDb.length;
    final points = <Offset>[];
    for (int i = 0; i < n; i++) {
      final x = (i / (n - 1)) * w;
      // Map -8 dB..+8 dB to h..0
      final norm = (gainsDb[i] / eqMaxGainDb).clamp(-1.0, 1.0);
      final y = zeroY - (norm * (h * 0.42));
      points.add(Offset(x, y));
    }

    // Build smooth cubic path
    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    // Draw gradient fill below curve
    final fillPath = Path.from(path)
      ..lineTo(w, zeroY)
      ..lineTo(0, zeroY)
      ..close();

    final accentColor = active
        ? const Color(0xFFE5B760)
        : (dark
            ? Colors.white.withValues(alpha: 0.54)
            : Colors.black.withValues(alpha: 0.38));

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accentColor.withValues(alpha: active ? 0.28 : 0.08),
          accentColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(fillPath, fillPaint);

    // Draw stroke line
    final linePaint = Paint()
      ..color = accentColor.withValues(alpha: active ? 0.95 : 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, linePaint);

    // Draw node dots
    final dotPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;
    for (final p in points) {
      canvas.drawCircle(p, 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    return oldDelegate.active != active ||
        oldDelegate.dark != dark ||
        oldDelegate.gainsDb != gainsDb;
  }
}
