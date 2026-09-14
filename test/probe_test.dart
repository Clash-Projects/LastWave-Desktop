import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/dio_factory.dart';

/// TEMPORARY diagnostic: hlsUrl + SABR presence per client.
void main() {
  test('hls matrix', () async {
    final dio = DioFactory.create();
    const videoId = 'fJ9rUzIMcZQ';
    final clients = [
      ('MWEB', '2.20260707.01.00',
          'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30'),
      ('TVHTML5', '7.20260308.08.00',
          'AIzaSyAO_FJ2SlqAz8GlBg1fA54p0wDE7Xk80mU'),
      ('ANDROID_MUSIC', '7.27.52',
          'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w'),
      ('IOS_MUSIC', '7.27.0',
          'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc'),
    ];
    for (final c in clients) {
      try {
        final res = await dio.post<String>(
          'https://www.youtube.com/youtubei/v1/player?key=${c.$3}&prettyPrint=false',
          data: jsonEncode({
            'context': {
              'client': {
                'clientName': c.$1,
                'clientVersion': c.$2,
                'hl': 'en',
                'gl': 'US',
              },
            },
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
          options: Options(headers: {
            'Content-Type': 'application/json',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
            'X-Goog-Api-Format-Version': '1',
          }),
        );
        final root =
            jsonDecode(res.data ?? '{}') as Map<String, dynamic>;
        final status =
            (root['playabilityStatus'] as Map?)?['status'];
        final sd = root['streamingData'] as Map?;
        final hls = sd?['hlsUrl']?.toString() ?? '';
        var sabr = 0;
        void scan(Object? node) {
          if (node is Map) {
            node.forEach((k, v) {
              if (k == 'url' &&
                  v is String &&
                  v.startsWith('sabr:')) {
                sabr++;
              }
              scan(v);
            });
          } else if (node is List) {
            for (final v in node) {
              scan(v);
            }
          }
        }

        scan(root);
        // ignore: avoid_print
        print(
            'HLS ${c.$1} status=$status hls=${hls.isNotEmpty} sabr=$sabr');
      } catch (e) {
        // ignore: avoid_print
        print('HLS ${c.$1} ERROR ${e.runtimeType}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
