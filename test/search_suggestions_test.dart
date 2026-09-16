import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/search/search_repository.dart';
import 'package:lastwave_desktop/ui/navigation/destinations.dart';

void main() {
  group('suggestionNameMatchesQuery', () {
    test('matches artist names for a typed prefix', () {
      expect(suggestionNameMatchesQuery('Metro Boomin', 'metro'), isTrue);
      expect(suggestionNameMatchesQuery('Metro Boomin', 'metro boomin'), isTrue);
      expect(suggestionNameMatchesQuery('Too Many Nights', 'metro'), isFalse);
    });

    test('matches a song title the user is typing', () {
      expect(suggestionNameMatchesQuery('Too Many Nights', 'too many'), isTrue);
      expect(suggestionNameMatchesQuery('Around Me', 'around'), isTrue);
    });
  });

  group('suggestionLooksLikeJunk', () {
    test('drops game/TV/edit complete hits', () {
      expect(suggestionLooksLikeJunk('metro man edit'), isTrue);
      expect(suggestionLooksLikeJunk('metro tv live'), isTrue);
      expect(suggestionLooksLikeJunk('metroid prime 4'), isTrue);
      expect(suggestionLooksLikeJunk('Metro Boomin'), isFalse);
      expect(suggestionLooksLikeJunk('Too Many Nights'), isFalse);
    });
  });

  group('waveActivePath', () {
    test('keeps Search selected when the query string is present', () {
      expect(waveActivePath('/search?q=metro%20boomin'), '/search');
      expect(waveActivePath('/home'), '/home');
      expect(waveRoutePath('/search?q=metro'), '/search');
    });
  });
}
