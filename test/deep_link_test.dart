import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/deep_link.dart';

void main() {
  test('reads the room code from a jam link', () {
    expect(jamCodeFromLink('lastwave://jam?code=abc123'), 'ABC123');
    expect(routeForLink('lastwave://jam?code=ABC123'), '/jam?code=ABC123');
    expect(jamCodeFromLink('LASTWAVE://JAM?code=xy9z'), 'XY9Z');
  });

  test('rejects anything else', () {
    expect(jamCodeFromLink('lastwave://jam'), isNull);
    expect(jamCodeFromLink('lastwave://jam?code='), isNull);
    expect(jamCodeFromLink('lastwave://jam?code=../../x'), isNull);
    expect(jamCodeFromLink('lastwave://other?code=ABC123'), isNull);
    expect(jamCodeFromLink('https://example.com/jam?code=ABC123'), isNull);
    expect(routeForLink('not a link'), isNull);
  });
}
