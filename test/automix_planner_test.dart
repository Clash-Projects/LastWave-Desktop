import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/player/mix_planner.dart';

MixTrackInfo t(String title,
        {String artist = 'A', String album = '', int seconds = 200}) =>
    MixTrackInfo(
      title: title,
      artist: artist,
      album: album,
      duration: Duration(seconds: seconds),
    );

void main() {
  group('filter errors are not stream errors', () {
    test('mpv filter-chain lines are classified as filter errors', () {
      // Exact lines from a user's mpv.log / media_kit error stream.
      expect(isFilterGraphError('Audio filter initialized failed!'), isTrue);
      expect(isFilterGraphError("AVFilterGraph: No such filter: 'lowpass'"),
          isTrue);
      expect(isFilterGraphError("Creating filter 'lavfi' failed."), isTrue);
    });

    test('real stream failures still go to the retry path', () {
      expect(isFilterGraphError('Failed to open <url>'), isFalse);
      expect(isFilterGraphError('tcp: Connection reset by peer'), isFalse);
    });
  });

  group('MixPlanner', () {
    test('mixes two unrelated songs with the requested overlap', () {
      final plan = MixPlanner.plan(
        outgoing: t('One', seconds: 240),
        incoming: t('Two', artist: 'B', seconds: 240),
        requested: const Duration(seconds: 20),
        sweepAvailable: true,
      );
      expect(plan.mixes, isTrue);
      expect(plan.overlap, const Duration(seconds: 20));
      expect(plan.style, MixStyle.filterSweep);
    });

    test('falls back to a volume blend when the sweep is unsupported', () {
      final plan = MixPlanner.plan(
        outgoing: t('One'),
        incoming: t('Two'),
        requested: const Duration(seconds: 20),
        sweepAvailable: false,
      );
      expect(plan.style, MixStyle.blend);
    });

    test('short songs get a shorter overlap', () {
      // 120s song: 18s would eat 15% of it; capped at 12%.
      final plan = MixPlanner.plan(
        outgoing: t('Namastute', seconds: 120),
        incoming: t('No Cap', seconds: 205),
        requested: const Duration(seconds: 18),
        sweepAvailable: false,
      );
      expect(plan.mixes, isTrue);
      expect(plan.overlap, const Duration(seconds: 14));
      expect(plan.reason, 'shortened');
    });

    test('DJ curve keeps the outgoing track up through its ending', () {
      final (o40, i40) = MixPlanner.djGains(0.4);
      expect(o40, closeTo(1, 1e-9));
      expect(i40, greaterThan(0.8));
      final (o1, i1) = MixPlanner.djGains(1);
      expect(o1, closeTo(0, 1e-9));
      expect(i1, closeTo(1, 1e-9));
      final (o0, i0) = MixPlanner.djGains(0);
      expect(o0, 1);
      expect(i0, 0);
    });

    test('consecutive album tracks stay gapless', () {
      final plan = MixPlanner.plan(
        outgoing: t('Track 1', album: 'The Album'),
        incoming: t('Track 2', album: 'The Album (Deluxe)'),
        requested: const Duration(seconds: 20),
        sweepAvailable: true,
      );
      expect(plan.mixes, isFalse);
      expect(plan.reason, 'album');
    });

    test('live recordings and podcasts are not mixed', () {
      for (final title in ['Song (Live)', 'Song - Live at Wembley',
          'Podcast Episode 12']) {
        final plan = MixPlanner.plan(
          outgoing: t('Studio'),
          incoming: t(title),
          requested: const Duration(seconds: 20),
          sweepAvailable: true,
        );
        expect(plan.mixes, isFalse, reason: title);
      }
      // A title that merely contains the word is still mixed.
      final plan = MixPlanner.plan(
        outgoing: t('Studio'),
        incoming: t('Live Your Life'),
        requested: const Duration(seconds: 20),
        sweepAvailable: true,
      );
      expect(plan.mixes, isTrue);
    });

    test('gain curve is equal-power and smooth at both ends', () {
      final (o0, i0) = MixPlanner.gains(0);
      final (o1, i1) = MixPlanner.gains(1);
      expect(o0, closeTo(1, 1e-9));
      expect(i0, closeTo(0, 1e-9));
      expect(o1, closeTo(0, 1e-9));
      expect(i1, closeTo(1, 1e-9));
      for (var p = 0.0; p <= 1.0; p += 0.05) {
        final (o, i) = MixPlanner.gains(p);
        expect(o * o + i * i, closeTo(1, 1e-9));
      }
      // Slow start: the incoming track creeps in.
      final (_, early) = MixPlanner.gains(0.1);
      expect(early, lessThan(0.1));
    });
  });
}
