import 'package:fluent_ui/fluent_ui.dart';

import '../ui/theme/tokens.dart';

/// Thin Wave skeleton primitives: static ledger shapes, no shimmer
/// (reduced-motion safe). Radii follow [WaveRadius]; no radius >= 16.
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = WaveRadius.artwork,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: dark
            ? WaveColors.surfaceOverlay
            : WaveColors.lightOverlay,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class SkeletonRow extends StatelessWidget {
  final int count;
  const SkeletonRow({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (i) => const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: WaveSpacing.x4, vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: SkeletonBox(
                    width: 16, height: 12, radius: 4),
              ),
              SkeletonBox(width: 40, height: 40),
              SizedBox(width: WaveSpacing.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 180, height: 12),
                    SizedBox(height: 6),
                    SkeletonBox(width: 120, height: 10),
                  ],
                ),
              ),
              SkeletonBox(width: 48, height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class SkeletonRail extends StatelessWidget {
  final int count;
  const SkeletonRail({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        separatorBuilder: (_, _) =>
            const SizedBox(width: WaveSpacing.x12),
        itemBuilder: (_, _) => const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: 168, height: 168),
            SizedBox(height: WaveSpacing.x4),
            SkeletonBox(width: 120, height: 12),
            SizedBox(height: 6),
            SkeletonBox(width: 90, height: 10),
          ],
        ),
      ),
    );
  }
}

/// Editorial feature skeleton: large artwork + ledger lines.
class SkeletonFeature extends StatelessWidget {
  const SkeletonFeature({super.key});
  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBox(width: 272, height: 272),
        SizedBox(width: WaveSpacing.x20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: 120, height: 12),
              SizedBox(height: 8),
              SkeletonBox(width: 280, height: 28),
              SizedBox(height: 8),
              SkeletonBox(width: 200, height: 14),
              SizedBox(height: 16),
              SkeletonBox(
                  width: 160,
                  height: 36,
                  radius: WaveRadius.controls),
            ],
          ),
        ),
      ],
    );
  }
}
