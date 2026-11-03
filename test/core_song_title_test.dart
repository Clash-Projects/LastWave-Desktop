import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

void main() {
  test('video-style titles reduce to the song name', () {
    expect(
      InnerTubeMusicApi.coreSongTitle(
        'RAGE - Sirf Tum ft. @dikzofficial (Anime Music Video)',
        'Rage The Rapper',
      ),
      'Sirf Tum',
    );
    expect(
      InnerTubeMusicApi.coreSongTitle('Espresso', 'Sabrina Carpenter'),
      'Espresso',
    );
    expect(
      InnerTubeMusicApi.coreSongTitle(
          'Love - Remix (Official Video)', 'Someone Else'),
      'Love - Remix',
    );
  });
}
