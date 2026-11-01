import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/video/video_match.dart';
import 'package:lastwave_desktop/features/video/ytdlp_tools.dart';

const _tvUa =
    'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold '
    '(unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)';
const _vrUa =
    'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; '
    'Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

Map<String, Object?> _format(
  String id, {
  String protocol = 'https',
  String vcodec = 'none',
  String acodec = 'none',
  int? height,
  double fps = 0,
  double tbr = 0,
  String ext = 'mp4',
  String ua = _tvUa,
}) => {
  'format_id': id,
  'url': 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=$id',
  'protocol': protocol,
  'vcodec': vcodec,
  'acodec': acodec,
  'height': height,
  'fps': fps,
  'tbr': tbr,
  'ext': ext,
  'http_headers': {
    'User-Agent': ua,
    'Accept': 'text/html',
    'Accept-Language': 'en-us',
    'Sec-Fetch-Mode': 'navigate',
  },
};

void main() {
  final json = {
    'id': 'CniQpzPua6A',
    'formats': [
      _format('sb0', protocol: 'mhtml', vcodec: 'none', acodec: 'none'),
      _format('251', acodec: 'opus', ext: 'webm', tbr: 130),
      _format('18', vcodec: 'avc1.42001E', acodec: 'mp4a.40.2', height: 360),
      _format('137', vcodec: 'avc1.640028', height: 1080, fps: 30, tbr: 4000),
      _format('313', vcodec: 'vp9', height: 2160, fps: 30, ext: 'webm'),
      _format('401', vcodec: 'av01.0.12M.08', height: 2160, ua: _vrUa),
      _format('96', protocol: 'm3u8_native', vcodec: 'avc1', height: 1080),
    ],
  };

  test('keeps https pictures and soundtracks, drops manifests', () {
    final streams = parseYtDlpFormats(json);
    expect(streams.map((s) => s.url.split('itag=').last), [
      '251',
      '18',
      '137',
      '313',
      '401',
    ]);
    final audio = streams.firstWhere((s) => s.audioOnly);
    expect(audio.height, 0);
    expect(audio.codec, 'opus');
    expect(streams.firstWhere((s) => s.height == 360).muxed, isTrue);
    expect(streams.firstWhere((s) => s.height == 1080).bitrate, 4000000);
  });

  test('carries the client headers but not Accept headers', () {
    final s = parseYtDlpFormats(json).firstWhere((s) => s.height == 1080);
    expect(s.requestHeaders['User-Agent'], _tvUa);
    expect(s.requestHeaders.containsKey('Accept'), isFalse);
    expect(s.requestHeaders.containsKey('Accept-Language'), isFalse);
    expect(s.requestHeaders['Sec-Fetch-Mode'], 'navigate');
  });

  test('names the YouTube client each link belongs to', () {
    final streams = parseYtDlpFormats(json);
    expect(streams.firstWhere((s) => s.codec == 'vp9').client, 'yt-dlp/tv');
    expect(
      streams.firstWhere((s) => s.codec.startsWith('av01')).client,
      'yt-dlp/android_vr',
    );
  });

  test('4K from yt-dlp is what a 4K choice plays', () {
    final ranked = rankVideoStreams(
      parseYtDlpFormats(json).where((s) => !s.audioOnly).toList(),
      2160,
    );
    expect(ranked.first.height, 2160);
  });

  test('bad output gives nothing', () {
    expect(parseYtDlpFormats(null), isEmpty);
    expect(parseYtDlpFormats({'formats': 'x'}), isEmpty);
  });
}
