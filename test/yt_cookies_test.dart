import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

void main() {
  test('header string passes through normalized', () {
    final out = InnerTubeMusicApi.normalizeCookies(
        'SID=aaa; __Secure-3PAPISID=bbb; HSID=ccc');
    expect(out, contains('SID=aaa'));
    expect(out, contains('__Secure-3PAPISID=bbb'));
    expect(out, contains('HSID=ccc'));
  });

  test('netscape cookies.txt extracts pairs', () {
    const txt = '# Netscape HTTP Cookie File\n'
        '.youtube.com\tTRUE\t/\tTRUE\t123\tSID\taaa\n'
        '#HttpOnly .youtube.com\tTRUE\t/\tTRUE\t123\t__Secure-3PAPISID\tbbb\n'
        '.youtube.com\tTRUE\t/\tTRUE\t123\tLOGIN_INFO\tccc\n';
    final out = InnerTubeMusicApi.normalizeCookies(txt);
    expect(out, contains('SID=aaa'));
    expect(out, contains('__Secure-3PAPISID=bbb'));
    expect(out, contains('LOGIN_INFO=ccc'));
  });

  test('multiline + Cookie: prefix handled', () {
    const raw = 'Cookie: SID=aaa; HSID=zzz\nSAPISID=mmm; SSID=nnn';
    final out = InnerTubeMusicApi.normalizeCookies(raw);
    expect(out, contains('SAPISID=mmm'));
    expect(out, contains('SSID=nnn'));
  });

  test('JSON array export handled', () {
    const raw =
        '[{"name":"SID","value":"aaa"},{"name":"SAPISID","value":"bbb"}]';
    final out = InnerTubeMusicApi.normalizeCookies(raw);
    expect(out, contains('SID=aaa'));
    expect(out, contains('SAPISID=bbb'));
  });

  test('missing SAPISID throws', () {
    expect(() => InnerTubeMusicApi.normalizeCookies('SID=aaa; HSID=bbb'),
        throwsFormatException);
  });

  test('empty throws', () {
    expect(() => InnerTubeMusicApi.normalizeCookies('   '),
        throwsFormatException);
  });
}
