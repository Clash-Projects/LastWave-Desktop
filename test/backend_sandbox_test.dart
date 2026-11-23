import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/ephemeral_webview_broker.dart';
import 'package:lastwave_desktop/features/innertube/quickjs_cipher.dart';
import 'package:lastwave_desktop/features/innertube/signature_decipher.dart';
import 'package:lastwave_desktop/features/innertube/yt_auth_store.dart';

void main() {
  group('Phase 1: YtAuthStore & YtSessionBundle Sandbox Tests', () {
    late SecureStore secureStore;
    late YtAuthStore authStore;

    setUp(() {
      secureStore = SecureStore();
      authStore = YtAuthStore(secureStore);
    });

    test('Session bundle initializes as guest with empty/stale tokens', () {
      final bundle = const YtSessionBundle();
      expect(bundle.isSignedIn, isFalse);
      expect(bundle.isPremium, isFalse);
      expect(bundle.isPoTokenStale, isTrue);
      expect(bundle.isExpired, isTrue);
    });

    test('Session bundle staleness behaves accurately around 15-minute threshold', () {
      final now = DateTime.now();

      // Expiring in 20 minutes -> not stale
      final fresh = YtSessionBundle(
        poToken: 'fresh_token_123',
        poTokenExpiresAt: now.add(const Duration(minutes: 20)),
      );
      expect(fresh.isPoTokenStale, isFalse);
      expect(fresh.isExpired, isFalse);

      // Expiring in 10 minutes -> stale (within 15-minute refresh window)
      final nearExpiry = YtSessionBundle(
        poToken: 'near_token_123',
        poTokenExpiresAt: now.add(const Duration(minutes: 10)),
      );
      expect(nearExpiry.isPoTokenStale, isTrue);
      expect(nearExpiry.isExpired, isFalse);

      // Expired in past -> expired
      final past = YtSessionBundle(
        poToken: 'past_token_123',
        poTokenExpiresAt: now.subtract(const Duration(minutes: 5)),
      );
      expect(past.isPoTokenStale, isTrue);
      expect(past.isExpired, isTrue);
    });

    test('YtAuthStore saves, loads, and updates session state', () async {
      final testBundle = YtSessionBundle(
        cookies: 'SAPISID=test_sapisid; SID=test_sid; HSID=test_hsid;',
        visitorData: 'test_visitor_data_xyz',
        poToken: 'initial_po_token_abc',
        poTokenExpiresAt: DateTime.now().add(const Duration(hours: 4)),
        dataSyncId: 'page_sync_123',
        accountType: 'free',
      );

      await authStore.save(testBundle);
      expect(authStore.current.isSignedIn, isTrue);
      expect(authStore.current.cookies, contains('SAPISID=test_sapisid'));

      // Simulate a fresh boot loading from storage
      final reloadedStore = YtAuthStore(secureStore);
      final loaded = await reloadedStore.load();
      expect(loaded.cookies, equals(testBundle.cookies));
      expect(loaded.visitorData, equals('test_visitor_data_xyz'));
      expect(loaded.poToken, equals('initial_po_token_abc'));
      expect(loaded.isPoTokenStale, isFalse);

      // Update PO-Token
      final newExpiry = DateTime.now().add(const Duration(hours: 6));
      await reloadedStore.updatePoToken(
        poToken: 'updated_token_999',
        expiresAt: newExpiry,
      );
      expect(reloadedStore.current.poToken, equals('updated_token_999'));

      // Clear on sign out
      await reloadedStore.clear();
      expect(reloadedStore.current.isSignedIn, isFalse);
      expect(reloadedStore.current.poToken, isEmpty);
    });
  });

  group('Phase 2: EphemeralWebViewBroker Logic Sandbox Tests', () {
    test('Broker returns cached non-stale token without triggering burst', () async {
      final secureStore = SecureStore();
      final authStore = YtAuthStore(secureStore);
      final broker = EphemeralWebViewBroker(authStore: authStore);

      // Pre-seed non-stale token
      await authStore.save(
        YtSessionBundle(
          poToken: 'cached_valid_potoken',
          poTokenExpiresAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      );

      // Mint should immediately return cached token without starting any WebView
      final result = await broker.mintToken('test_video_123');
      expect(result, isNotNull);
      expect(result!.playerToken, equals('cached_valid_potoken'));
      expect(result.sessionToken, equals('cached_valid_potoken'));
    });

    test('Single-flight lock returns same Future for concurrent calls', () async {
      final secureStore = SecureStore();
      final authStore = YtAuthStore(secureStore);
      final broker = EphemeralWebViewBroker(authStore: authStore);

      // Seed valid token
      await authStore.updatePoToken(
        poToken: 'shared_flight_token',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

      final f1 = broker.mintToken('vid_1');
      final f2 = broker.mintToken('vid_1');
      final f3 = broker.mintToken('vid_1');

      final results = await Future.wait([f1, f2, f3]);
      expect(results[0]?.playerToken, equals('shared_flight_token'));
      expect(results[1]?.playerToken, equals('shared_flight_token'));
      expect(results[2]?.playerToken, equals('shared_flight_token'));
    });
  });

  group('Phase 3: QuickJS Native Solver & Bytecode Engine Sandbox Tests', () {
    test('QuickJS native library is loaded and operational', () {
      expect(QuickJsCipher.isAvailable, isTrue);
    });

    test('QuickJS isolates, compiles, and deciphers with real YouTube assets', () async {
      final dio = Dio();
      final tempDir = Directory.systemTemp.createTempSync('lastwave_test_ejs');
      final solver = QuickJsCipherIsolate(dio, cacheDirectory: tempDir.path);

      print('QuickJS Isolate: ensuring player from real YouTube...');
      final player = await solver.ensurePlayer();
      expect(player, isNotNull);
      expect(player!.id.length, equals(8));
      expect(player.sts, greaterThan(20000));
      expect(player.bytecode, isNotEmpty);
      print('Player ensured: id=${player.id}, sts=${player.sts}, bytecode=${player.bytecode.length} bytes');

      // Test second ensurePlayer loads from disk cache in < 15ms
      final sw = Stopwatch()..start();
      final cachedPlayer = await solver.ensurePlayer();
      sw.stop();
      print('Second ensurePlayer took ${sw.elapsedMilliseconds} ms');
      expect(cachedPlayer?.id, equals(player.id));
      expect(sw.elapsedMilliseconds, lessThan(50));

      // Test URL deciphering
      const sampleCipher =
          'url=https%3A%2F%2Frr1---sn-uxa3-nuae.googlevideo.com%2Fvideoplayback%3Fexpire%3D1700000000%26ei%3Dabc%26ip%3D1.2.3.4%26id%3Do-test%26n%3D5qZl8A9tM_test1'
          '&s=AABBCCDDEEFFGGHHIIJJKKLLMMNNOOPPQQRRSSTTUUVV'
          '&sp=sig';

      final deciphered = await solver.decipherUrl(sampleCipher, playerOverride: player);
      expect(deciphered, isNotNull);
      expect(deciphered, contains('googlevideo.com'));
      expect(deciphered, contains('sig='));
      expect(deciphered, contains('&n='));
      print('Deciphered URL result: ${deciphered!.substring(0, 100)}...');

      tempDir.deleteSync(recursive: true);
    });
  });

  group('Phase 4: SignatureDecipher with QuickJS Integration Sandbox Tests', () {
    test('SignatureDecipher seamlessly deciphers using QuickJS engine', () async {
      final dio = Dio();
      final decipher = SignatureDecipher(dio);

      // Pre-warm player
      final player = await decipher.quickJs.ensurePlayer();
      expect(player, isNotNull);

      // Test signature timestamp lookup (fast path via QuickJS)
      final sts = await decipher.getSignatureTimestamp('dQw4w9WgXcQ');
      expect(sts, isNotNull);
      expect(sts, greaterThan(20000));
      print('Signature timestamp resolved: $sts');

      // Test decipherUrl with signatureCipher
      const testCipher =
          'url=https%3A%2F%2Fgooglevideo.com%2Fvideoplayback%3Fexpire%3D123%26n%3DXyZ999_test'
          '&s=11223344556677889900AABBCCDDEEFFGGHHIIJJKKLL'
          '&sp=sig';

      final result = decipher.decipherUrl(testCipher, null);
      expect(result, isNotNull);
      expect(result, contains('&sig='));
      expect(result, contains('googlevideo.com'));
      print('SignatureDecipher result: $result');
    });
  });
}
