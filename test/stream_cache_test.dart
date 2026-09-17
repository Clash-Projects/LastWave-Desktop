import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';

void main() {
  group('ResolvedStreamCache', () {
    test('returns a fresh entry and drops an expired one', () {
      final cache = ResolvedStreamCache(maxEntries: 4);
      const fresh = ResolvedStream(
        url: 'https://example.com/a.flac',
        cacheKey: 'lossless:1:6',
        isLossless: true,
      );
      final expired = ResolvedStream(
        url: 'https://example.com/b.flac',
        cacheKey: 'lossless:2:6',
        isLossless: true,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      cache.put('a', fresh);
      cache.put('b', expired);

      expect(cache.get('a')?.url, fresh.url);
      expect(cache.get('b'), isNull);
      expect(cache.length, 1);
    });

    test('evicts oldest entries past maxEntries', () {
      final cache = ResolvedStreamCache(maxEntries: 2);
      for (var i = 0; i < 3; i++) {
        cache.put(
          '$i',
          ResolvedStream(
            url: 'https://example.com/$i.flac',
            cacheKey: 'k$i',
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          ),
        );
      }
      expect(cache.length, 2);
      expect(cache.get('0'), isNull);
      expect(cache.get('1'), isNotNull);
      expect(cache.get('2'), isNotNull);
    });

    test('isExpired uses a two-minute safety margin', () {
      final soon = ResolvedStream(
        url: 'https://example.com/c.flac',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(soon.isExpired, isTrue);
      final later = ResolvedStream(
        url: 'https://example.com/d.flac',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      expect(later.isExpired, isFalse);
    });
  });
}
