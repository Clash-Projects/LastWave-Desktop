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
  final VoidCallback? onClose;
  final bool embedded;
  const WaveEqualizerPanel({
    super.key,
    this.onClose,
    this.embedded = false,
  });

  @override
  ConsumerState<WaveEqualizerPanel> createState() => _WaveEqualizerPanelState();
}

class _WaveEqualizerPanelState extends ConsumerState<WaveEqualizerPanel> {
  int _selectedTab = 0; // 0 = 10-Band EQ, 1 = Studio Master Clarity
  late final ScrollController _eqScrollController;
  late final ScrollController _clarityScrollController;

  @override
  void initState() {
    super.initState();
    _eqScrollController = ScrollController();
    _clarityScrollController = ScrollController();
  }

  @override
  void dispose() {
    _eqScrollController.dispose();
    _clarityScrollController.dispose();
    super.dispose();
  }

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
        border: widget.embedded
            ? Border.all(
                color: waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
                width: 1,
              )
            : Border(
                left: BorderSide(
                  color: waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
                  width: 1,
                ),
              ),
        borderRadius:
            widget.embedded ? BorderRadius.circular(WaveRadius.menu) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          _buildHeader(context, dark, eq, notifier),

          // Tab Selector: 10-Band EQ vs Studio Master Clarity
          _buildTabSelector(context, dark, eq),

          // Content body
          Expanded(
            child: _selectedTab == 0
                ? _build10BandView(context, dark, eq, notifier)
                : _buildStudioClarityView(context, dark, eq, notifier),
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
    String statusSubtitle;
    if (!eq.isProcessingActive) {
      statusSubtitle = 'Bypassed (Bit-Perfect output)';
    } else if (eq.studioClarityEnabled && eq.enabled) {
      statusSubtitle = 'Studio Clarity + ${eq.presetName}';
    } else if (eq.studioClarityEnabled) {
      statusSubtitle = 'Studio Master Clarity (${eq.clarityPreset.displayName})';
    } else {
      statusSubtitle = '${eq.presetName} preset active';
    }

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
                  'Equalizer & Sound FX',
                  style: WaveType.sectionTitle.copyWith(fontSize: 14),
                ),
                Text(
                  statusSubtitle,
                  style: WaveType.meta.copyWith(
                    fontSize: 11,
                    color: eq.isProcessingActive
                        ? (eq.studioClarityEnabled
                            ? const Color(0xFFF5A623)
                            : WaveColors.defaultAccent)
                        : waveTextSecondary(context),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Master EQ switch
          ToggleSwitch(
            checked: eq.enabled,
            onChanged: (val) => notifier.setEnabled(val),
          ),
          const SizedBox(width: 8),
          // Reset button
          LWTooltip(
            message: 'Reset all bands to flat (0 dB)',
            child: IconButton(
              icon: Icon(
                FluentIcons.refresh,
                size: 13,
                color: waveTextSecondary(context),
              ),
              onPressed: notifier.reset,
            ),
          ),
          if (widget.onClose != null) ...[
            const SizedBox(width: 4),
            // Close button
            LWTooltip(
              message: 'Close panel',
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
        ],
      ),
    );
  }

  Widget _buildTabSelector(BuildContext context, bool dark, EqualizerState eq) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: waveDivider(context).withValues(alpha: dark ? 0.2 : 0.35),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TabButton(
              title: '10-Band EQ',
              icon: FluentIcons.equalizer,
              selected: _selectedTab == 0,
              badgeActive: eq.enabled,
              dark: dark,
              onTap: () => setState(() => _selectedTab = 0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TabButton(
              title: 'Studio Clarity',
              icon: FluentIcons.favorite_star_fill,
              selected: _selectedTab == 1,
              badgeActive: eq.studioClarityEnabled,
              dark: dark,
              onTap: () => setState(() => _selectedTab = 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _build10BandView(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    return Scrollbar(
      controller: _eqScrollController,
      interactive: true,
      child: ListView(
        controller: _eqScrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Frequency response visualizer
          _buildVisualizer(context, dark, eq),
          const SizedBox(height: 12),

          // Presets chip selector
          _buildPresetSelector(context, dark, eq, notifier),
          const SizedBox(height: 14),

          // 10-band custom vertical bar rack
          _buildSliderRack(context, dark, eq, notifier),
          const SizedBox(height: 12),

          // Quick toolbar
          _buildQuickToolbar(context, dark, eq, notifier),
          const SizedBox(height: 12),

          // Footer status note
          _buildFooterNote(context, dark, eq),
        ],
      ),
    );
  }

  Widget _buildStudioClarityView(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    final active = eq.studioClarityEnabled;
    return Scrollbar(
      controller: _clarityScrollController,
      interactive: true,
      child: ListView(
        controller: _clarityScrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
        // Studio Master Clarity hero card
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WaveRadius.menu),
            color: active
                ? (dark ? const Color(0xFF1F1B14) : const Color(0xFFFFF9ED))
                : (dark ? waveSurfaceRaised(context) : WaveColors.lightOverlay),
            border: Border.all(
              color: active
                  ? (dark
                      ? const Color(0xFF8A6D3B).withValues(alpha: 0.8)
                      : const Color(0xFFE5B760))
                  : waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
              width: active ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: active
                          ? const Color(0xFFF5A623).withValues(alpha: 0.18)
                          : (dark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.05)),
                    ),
                    child: Icon(
                      FluentIcons.favorite_star_fill,
                      size: 18,
                      color: active
                          ? const Color(0xFFF5A623)
                          : waveTextSecondary(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Studio Master Clarity',
                          style: WaveType.body.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: active
                                ? (dark ? Colors.white : const Color(0xFF5A3E00))
                                : waveTextPrimary(context),
                          ),
                        ),
                        Text(
                          'Audiophile reference curve ported from LastWave Native',
                          style: WaveType.meta.copyWith(
                            fontSize: 11,
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
              const SizedBox(height: 12),
              Text(
                'Engineered to eliminate low-mid boxiness, tighten sub-bass control, preserve natural vocal body, and introduce a transparent, silky high-frequency air shelf.',
                style: WaveType.meta.copyWith(
                  fontSize: 11,
                  color: waveTextSecondary(context),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Acoustic Target Profile Selector
        Text(
          'ACOUSTIC TARGET PROFILE',
          style: WaveType.overline.copyWith(
            color: waveTextSecondary(context),
          ),
        ),
        const SizedBox(height: 8),

        for (final target in ClarityPresets.all) ...[
          _buildTargetOptionCard(context, dark, target, eq, notifier),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 12),

        // Target Frequency Curve Preview
        Container(
          height: 80,
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
                active: eq.studioClarityEnabled,
                dark: dark,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    ),
  );
}

  Widget _buildTargetOptionCard(
    BuildContext context,
    bool dark,
    ClarityPreset target,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    final isSelected = eq.clarityPresetKey == target.key;
    final active = eq.studioClarityEnabled;

    return GestureDetector(
      onTap: () => notifier.setClarityPreset(target.key),
      child: AnimatedContainer(
        duration: waveMotion(context, const Duration(milliseconds: 140)),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(WaveRadius.menu),
          color: isSelected
              ? (dark
                  ? const Color(0xFF2B2418)
                  : const Color(0xFFFFF3D6))
              : (dark
                  ? waveSurfaceRaised(context)
                  : WaveColors.lightOverlay),
          border: Border.all(
            color: isSelected
                ? (dark ? const Color(0xFFF5A623) : const Color(0xFFE5B760))
                : waveDivider(context).withValues(alpha: dark ? 0.25 : 0.4),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFFF5A623)
                      : waveTextSecondary(context).withValues(alpha: 0.5),
                  width: 2,
                ),
                color: isSelected && active
                    ? const Color(0xFFF5A623)
                    : Colors.transparent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.displayName,
                    style: WaveType.body.copyWith(
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                      fontSize: 12.5,
                      color: isSelected
                          ? (dark ? Colors.white : const Color(0xFF5A3E00))
                          : waveTextPrimary(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    target.description,
                    style: WaveType.meta.copyWith(
                      fontSize: 10.5,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizer(
    BuildContext context,
    bool dark,
    EqualizerState eq,
  ) {
    return Container(
      height: 76,
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
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: EqualizerPresets.all.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final preset = EqualizerPresets.all[index];
          final isSelected =
              eq.presetName.toLowerCase() == preset.name.toLowerCase();
          final isStudioMaster =
              preset.name == EqualizerPresets.studioMaster.name;

          return GestureDetector(
            onTap: () => notifier.applyPreset(preset),
            child: AnimatedContainer(
              duration:
                  waveMotion(context, const Duration(milliseconds: 140)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: isSelected
                    ? (isStudioMaster
                        ? (dark
                            ? const Color(0xFF8A6D3B)
                            : const Color(0xFFE5B760))
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
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
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
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
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
            _VerticalEqBand(
              index: i,
              freqHz: eqBandFreqsHz[i],
              gainDb: gains[i],
              enabled: eq.enabled,
              dark: dark,
              onChanged: (val) => notifier.setBandGain(i, val),
              onReset: () => notifier.setBandGain(i, 0.0),
            ),
        ],
      ),
    );
  }

  Widget _buildQuickToolbar(
    BuildContext context,
    bool dark,
    EqualizerState eq,
    EqualizerNotifier notifier,
  ) {
    return Row(
      children: [
        _QuickActionPill(
          label: 'Flat (0 dB)',
          onTap: notifier.reset,
          dark: dark,
        ),
        const SizedBox(width: 6),
        _QuickActionPill(
          label: '+2 dB Bass',
          onTap: () async {
            for (int i = 0; i <= 2; i++) {
              await notifier.setBandGain(
                  i, (eq.gainsDb[i] + 2.0).clamp(-eqMaxGainDb, eqMaxGainDb));
            }
          },
          dark: dark,
        ),
        const SizedBox(width: 6),
        _QuickActionPill(
          label: '+2 dB Treble',
          onTap: () async {
            for (int i = 7; i <= 9; i++) {
              await notifier.setBandGain(
                  i, (eq.gainsDb[i] + 2.0).clamp(-eqMaxGainDb, eqMaxGainDb));
            }
          },
          dark: dark,
        ),
        const Spacer(),
        Text(
          'Double-click band to zero',
          style: WaveType.meta.copyWith(
            fontSize: 10,
            color: waveTextSecondary(context).withValues(alpha: 0.7),
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
                  ? 'Hardware-accelerated 32-bit float biquad filter applied via libmpv.'
                  : 'Bypassed: Audio stream flows directly to output with bit-perfect integrity.',
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

/// Custom interactive vertical mixing console equalizer band.
class _VerticalEqBand extends StatelessWidget {
  final int index;
  final int freqHz;
  final double gainDb;
  final bool enabled;
  final bool dark;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  static const double kTrackHeight = 150.0;

  const _VerticalEqBand({
    required this.index,
    required this.freqHz,
    required this.gainDb,
    required this.enabled,
    required this.dark,
    required this.onChanged,
    required this.onReset,
  });

  void _handleDrag(Offset localPos) {
    if (!enabled) return;
    // localPos.dy ranges from 0 (top = +eqMaxGainDb) to kTrackHeight (bottom = -eqMaxGainDb)
    final clampedY = localPos.dy.clamp(0.0, kTrackHeight);
    final norm = 1.0 - (clampedY / kTrackHeight); // 0.0 at bottom, 1.0 at top
    final gain = (norm * 2.0 - 1.0) * eqMaxGainDb; // -eqMaxGainDb .. +eqMaxGainDb
    final rounded = (gain * 10).round() / 10.0;
    onChanged(rounded);
  }

  @override
  Widget build(BuildContext context) {
    final isNonZero = gainDb.abs() >= 0.05;
    final gainText = gainDb > 0
        ? '+${gainDb.toStringAsFixed(1)}'
        : (gainDb < 0 ? gainDb.toStringAsFixed(1) : '0.0');

    // Calculate thumb position along track
    // normGain ranges from -1.0 (-8dB) to +1.0 (+8dB)
    final normGain = (gainDb / eqMaxGainDb).clamp(-1.0, 1.0);
    // 0 dB is at half height
    final zeroY = kTrackHeight / 2;
    final thumbY = zeroY - (normGain * zeroY);

    Color activeColor;
    if (gainDb > 0) {
      activeColor = WaveColors.defaultAccent;
    } else if (gainDb < 0) {
      activeColor = const Color(0xFF42A5F5);
    } else {
      activeColor = waveTextSecondary(context);
    }

    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // dB Readout (double tap to reset)
          GestureDetector(
            onDoubleTap: onReset,
            child: SizedBox(
              height: 18,
              child: Center(
                child: Text(
                  gainText,
                  style: WaveType.meta.copyWith(
                    fontSize: 9.5,
                    fontWeight: isNonZero ? FontWeight.w700 : FontWeight.normal,
                    color: isNonZero && enabled
                        ? activeColor
                        : waveTextSecondary(context).withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Interactive Track and Thumb
          MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (d) => _handleDrag(d.localPosition),
              onVerticalDragUpdate: (d) => _handleDrag(d.localPosition),
              onTapDown: (d) => _handleDrag(d.localPosition),
              onDoubleTap: onReset,
              child: SizedBox(
                width: 32,
                height: kTrackHeight,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    // Background track rail
                    Container(
                      width: 5,
                      height: kTrackHeight,
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xFF1B1B1B)
                            : const Color(0xFFE2E2E2),
                        borderRadius: BorderRadius.circular(2.5),
                        border: Border.all(
                          color: dark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.06),
                          width: 0.5,
                        ),
                      ),
                    ),

                    // 0 dB center reference line notch
                    Positioned(
                      top: zeroY - 0.75,
                      child: Container(
                        width: 14,
                        height: 1.5,
                        decoration: BoxDecoration(
                          color: dark
                              ? Colors.white.withValues(alpha: 0.22)
                              : Colors.black.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),

                    // Bipolar active fill bar
                    if (isNonZero && enabled)
                      Positioned(
                        top: gainDb > 0 ? thumbY : zeroY,
                        height: gainDb > 0 ? (zeroY - thumbY) : (thumbY - zeroY),
                        child: Container(
                          width: 5,
                          decoration: BoxDecoration(
                            color: activeColor,
                            borderRadius: BorderRadius.circular(2.5),
                            boxShadow: [
                              BoxShadow(
                                color: activeColor.withValues(alpha: 0.4),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),

                    // Draggable knob / thumb
                    Positioned(
                      top: thumbY - 8,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: dark
                              ? const Color(0xFF181818)
                              : Colors.white,
                          border: Border.all(
                            color: enabled
                                ? (isNonZero
                                    ? activeColor
                                    : (dark
                                        ? Colors.white.withValues(alpha: 0.7)
                                        : Colors.black.withValues(alpha: 0.87)))
                                : waveTextSecondary(context).withValues(alpha: 0.4),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: enabled && isNonZero
                                  ? activeColor
                                  : (dark
                                      ? Colors.white.withValues(alpha: 0.38)
                                      : Colors.black.withValues(alpha: 0.38)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Frequency label badge (double-click to reset)
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
                  color: isNonZero && enabled
                      ? waveTextPrimary(context)
                      : waveTextSecondary(context),
                  fontWeight: isNonZero && enabled
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool selected;
  final bool badgeActive;
  final bool dark;
  final VoidCallback onTap;

  const _TabButton({
    required this.title,
    required this.icon,
    required this.selected,
    required this.badgeActive,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: waveMotion(context, const Duration(milliseconds: 140)),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(WaveRadius.menu),
          color: selected
              ? (dark
                  ? waveSurfaceRaised(context)
                  : Colors.white)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6)
                : Colors.transparent,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.2 : 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected
                  ? (badgeActive ? const Color(0xFFF5A623) : waveTextPrimary(context))
                  : waveTextSecondary(context),
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: WaveType.body.copyWith(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected
                    ? waveTextPrimary(context)
                    : waveTextSecondary(context),
              ),
            ),
            if (badgeActive) ...[
              const SizedBox(width: 6),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFF5A623),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuickActionPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool dark;

  const _QuickActionPill({
    required this.label,
    required this.onTap,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: dark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.04),
          border: Border.all(
            color: waveDivider(context).withValues(alpha: dark ? 0.25 : 0.4),
          ),
        ),
        child: Text(
          label,
          style: WaveType.meta.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: waveTextSecondary(context),
          ),
        ),
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
