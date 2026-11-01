import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/features/video/video_match.dart';

bool matches(
  String title, {
  String channel = 'Label Records',
  int? seconds,
  required String song,
  String artist = 'Asha Singer',
  int? durationMs,
}) => isSameSongVideo(
  candidateTitle: title,
  candidateChannel: channel,
  candidateSeconds: seconds,
  songTitle: song,
  songArtist: artist,
  songDurationMs: durationMs,
);

void main() {
  group('isSameSongVideo (ported from LastWave-Native)', () {
    test('rejects a different song with a similar name', () {
      expect(
        matches(
          'Haseena',
          channel: 'Crishna',
          seconds: 200,
          song: 'Hosanna',
          artist: 'Crishna',
          durationMs: 200000,
        ),
        isFalse,
      );
    });
    test('rejects an official video for another song', () {
      expect(
        matches(
          'Abhijay Sharma - sheher (Official Music Video) | dir. harsh',
          channel: 'Abhijay Sharma',
          seconds: 180,
          song: 'Qissa',
          artist: 'Abhijay Sharma',
          durationMs: 180000,
        ),
        isFalse,
      );
    });
    test('accepts title with extras when it names the artist', () {
      expect(
        matches(
          'Aasmaan Jaley(Official Video) | Abhay J | Abhijeet S',
          song: 'Aasmaan Jaley',
          artist: 'Abhijeet Srivastava',
        ),
        isTrue,
      );
    });
    test('accepts label upload when length matches', () {
      expect(
        matches(
          'Kasturi | Amar Prem Ki Prem Kahani',
          channel: 'Tips',
          seconds: 240,
          song: 'Kasturi',
          durationMs: 233000,
        ),
        isTrue,
      );
    });
    test('rejects same title with other artist and length', () {
      expect(
        matches(
          'Kaagaz',
          channel: 'Other Person',
          seconds: 400,
          song: 'Kaagaz',
          durationMs: 205000,
        ),
        isFalse,
      );
    });
    test('rejects when length unknown and artist absent', () {
      expect(matches('Kaagaz', song: 'Kaagaz', durationMs: 205000), isFalse);
    });
    test('title must match whole words', () {
      expect(
        matches('Belonging', channel: 'Asha Singer', song: 'Belong'),
        isFalse,
      );
    });
    test('short artist words do not count', () {
      expect(
        matches(
          'Kaagaz',
          channel: 'The Other',
          song: 'Kaagaz',
          artist: 'The Singer',
        ),
        isFalse,
      );
    });
    test('other rendition does not match a versioned song', () {
      expect(
        matches(
          'Suroor',
          channel: 'Asha Singer',
          song: 'Suroor (2 am Version)',
        ),
        isFalse,
      );
    });
    test('matches non-Latin titles', () {
      expect(
        matches(
          'तुम ही हो | Official Video',
          channel: 'अरिजीत सिंह',
          song: 'तुम ही हो',
          artist: 'अरिजीत सिंह',
        ),
        isTrue,
      );
    });
    test('blank title never matches', () {
      expect(matches('Anything', song: '  '), isFalse);
    });
  });

  group('real-world titles', () {
    test('stage names with symbols still match (KR\$NA)', () {
      expect(
        matches(
          'KR\$NA - Boom Shaka (Official Music Video)',
          channel: 'KR\$NA',
          song: 'Boom Shaka',
          artist: 'KR\$NA',
        ),
        isTrue,
      );
      final score = scoreVideoCandidate(
        candidateTitle: 'KR\$NA - Boom Shaka (Official Music Video)',
        candidateArtist: 'KR\$NA',
        candidateDurationSec: 212,
        wantedTitle: 'Boom Shaka',
        wantedArtist: 'KR\$NA',
        expectedDurationMs: null,
      );
      expect(score, isNotNull);
      expect(score!, greaterThanOrEqualTo(minVideoCandidateScore));
    });

    test('Machayenge 4 official video is found without a known length', () {
      const title =
          'Emiway - Machayenge 4 (Prod by Flamboy) (Official Music Video)';
      expect(
        matches(
          title,
          channel: 'Emiway Bantai',
          song: 'Machayenge 4',
          artist: 'Emiway Bantai',
        ),
        isTrue,
      );
      final score = scoreVideoCandidate(
        candidateTitle: title,
        candidateArtist: 'Emiway Bantai',
        candidateDurationSec: 230,
        wantedTitle: 'Machayenge 4',
        wantedArtist: 'Emiway Bantai',
        expectedDurationMs: null,
      );
      expect(score, isNotNull);
      expect(score!, greaterThanOrEqualTo(minVideoCandidateScore));
    });

    test('another number in the series is a different song', () {
      expect(
        matches(
          'Emiway - Machayenge 3 (Official Music Video)',
          channel: 'Emiway Bantai',
          song: 'Machayenge 4',
          artist: 'Emiway Bantai',
        ),
        isFalse,
      );
      expect(
        matches(
          'Emiway - Machayenge (Official Music Video)',
          channel: 'Emiway Bantai',
          song: 'Machayenge 4',
          artist: 'Emiway Bantai',
        ),
        isFalse,
      );
    });

    test('a short stage name never matches by accident', () {
      expect(
        matches(
          'Some Rapper - Boom Shaka (Official Video)',
          channel: 'Some Rapper',
          song: 'Boom Shaka',
          artist: 'DJ',
        ),
        isFalse,
      );
    });
  });

  group('scoreVideoCandidate', () {
    test('official video on the artist channel clears the bar', () {
      final score = scoreVideoCandidate(
        candidateTitle: 'Paaro (Official Music Video)',
        candidateArtist: 'Aditya Rikhari',
        candidateDurationSec: 190,
        wantedTitle: 'Paaro',
        wantedArtist: 'Aditya Rikhari',
        expectedDurationMs: 188000,
      );
      expect(score, isNotNull);
      expect(score!, greaterThanOrEqualTo(minVideoCandidateScore));
    });
    test('gameplay upload using the song is rejected', () {
      expect(
        scoreVideoCandidate(
          candidateTitle: 'Paaro BGMI montage edit Aditya Rikhari',
          candidateArtist: 'Pro Gamer',
          candidateDurationSec: 190,
          wantedTitle: 'Paaro',
          wantedArtist: 'Aditya Rikhari',
          expectedDurationMs: 188000,
        ),
        isNull,
      );
    });
    test('remix and slowed uploads fall below the bar', () {
      final score = scoreVideoCandidate(
        candidateTitle: 'Paaro (Slowed + Reverb) Aditya Rikhari',
        candidateArtist: 'Lofi Vibes',
        candidateDurationSec: 240,
        wantedTitle: 'Paaro',
        wantedArtist: 'Aditya Rikhari',
        expectedDurationMs: 188000,
      );
      expect(score == null || score < minVideoCandidateScore, isTrue);
    });
    test('lyric video on a random channel is not accepted', () {
      expect(
        scoreVideoCandidate(
          candidateTitle: 'Paaro lyrics',
          candidateArtist: 'Lyrics Hub',
          candidateDurationSec: 188,
          wantedTitle: 'Paaro',
          wantedArtist: 'Aditya Rikhari',
          expectedDurationMs: 188000,
        ),
        isNull,
      );
    });
  });

  group('cleanTrackTitleForVideo', () {
    test('strips credits and labels but keeps versions', () {
      expect(
        cleanTrackTitleForVideo('Song (feat. Someone) [Official Video]'),
        'Song',
      );
      expect(cleanTrackTitleForVideo('Song (From "Film")'), 'Song');
      expect(
        cleanTrackTitleForVideo('Song (2 am Version)'),
        'Song (2 am Version)',
      );
    });
  });

  group('pickVideoStreamForQuality', () {
    final streams = [
      for (final h in [2160, 1440, 1080, 720, 480, 360])
        MusicVideoStream(label: '${h}p', url: 'u$h', height: h),
    ];
    test('auto caps at 1080p', () {
      expect(pickVideoStreamForQuality(streams, 0)!.height, 1080);
    });
    test('fixed height is honoured', () {
      expect(pickVideoStreamForQuality(streams, 2160)!.height, 2160);
      expect(pickVideoStreamForQuality(streams, 720)!.height, 720);
    });
    test('missing height falls to the nearest lower one', () {
      final some = streams.where((s) => s.height != 720).toList();
      expect(pickVideoStreamForQuality(some, 720)!.height, 480);
    });
    test('everything above the choice falls to the lowest', () {
      final big = streams.where((s) => s.height >= 1080).toList();
      expect(pickVideoStreamForQuality(big, 360)!.height, 1080);
    });
  });

  group('rankVideoStreams', () {
    MusicVideoStream st(
      int h, {
      String codec = 'avc1.640028',
      bool muxed = false,
      int fps = 30,
      int bitrate = 1000,
      String client = 'ANDROID_VR',
    }) => MusicVideoStream(
      label: '${h}p',
      url: 'u$h-$codec-$muxed-$fps-$bitrate-$client',
      height: h,
      codec: codec,
      muxed: muxed,
      fps: fps,
      bitrate: bitrate,
      client: client,
    );

    test('a client that only has 360p no longer caps the picture', () {
      final ranked = rankVideoStreams([
        st(360, muxed: true, client: 'ANDROID'),
        st(1080),
        st(720),
      ], 0);
      expect(ranked.first.height, 1080);
      expect(ranked.map((s) => s.height), [1080, 720, 360]);
    });

    test('same height prefers H.264 over VP9 over AV1', () {
      final ranked = rankVideoStreams([
        st(1080, codec: 'av01.0.08M.08'),
        st(1080, codec: 'vp9'),
        st(1080),
      ], 0);
      expect(ranked.map((s) => s.codec), [
        'avc1.640028',
        'vp9',
        'av01.0.08M.08',
      ]);
    });

    test('video-only beats the progressive file at the same height', () {
      final ranked = rankVideoStreams([
        st(720, muxed: true, codec: 'avc1.64001F'),
        st(720),
      ], 0);
      expect(ranked.first.muxed, isFalse);
    });

    test('30 fps beats 60 fps, then higher bitrate wins', () {
      final ranked = rankVideoStreams([
        st(1080, fps: 60, bitrate: 9000),
        st(1080, bitrate: 2000),
        st(1080, bitrate: 3000),
      ], 0);
      expect(ranked.map((s) => s.fps), [30, 30, 60]);
      expect(ranked.first.bitrate, 3000);
    });

    test('auto never starts above 1080p, a fixed choice can', () {
      final all = [
        st(2160, codec: 'vp9'),
        st(1440, codec: 'vp9'),
        st(1080),
        st(720),
      ];
      expect(rankVideoStreams(all, 0).first.height, 1080);
      expect(rankVideoStreams(all, 2160).first.height, 2160);
      expect(rankVideoStreams(all, 720).first.height, 720);
    });

    test('taller candidates only follow as a last resort, smallest first', () {
      final ranked = rankVideoStreams([
        st(2160, codec: 'vp9'),
        st(1440, codec: 'vp9'),
        st(1080),
      ], 720);
      expect(ranked.map((s) => s.height), [1080, 1440, 2160]);
    });

    test('empty input stays empty', () {
      expect(rankVideoStreams(const [], 0), isEmpty);
      expect(pickVideoStreamForQuality(const [], 0), isNull);
    });
  });

  group('pickSongAudioCandidate', () {
    SongAudioCandidate row(String id, String title, String artist, int sec) =>
        (id: id, title: title, artist: artist, seconds: sec);

    test('finds the studio audio for a track with no YouTube id', () {
      expect(
        pickSongAudioCandidate(
          [
            row('live1', 'Machayenge 4 (Live)', 'KR\$NA', 230),
            row('studio', 'Machayenge 4', 'KR\$NA', 228),
          ],
          title: 'Machayenge 4',
          artist: 'KR\$NA',
          durationMs: null,
        ),
        'studio',
      );
    });

    test('rejects other songs, other artists and other lengths', () {
      final rows = [
        row('a', 'Machayenge 3', 'KR\$NA', 228),
        row('b', 'Machayenge 4', 'Somebody Else', 228),
        row('c', 'Machayenge 4', 'KR\$NA', 300),
      ];
      expect(
        pickSongAudioCandidate(
          rows,
          title: 'Machayenge 4',
          artist: 'KR\$NA',
          durationMs: 228000,
        ),
        isNull,
      );
    });

    test('never returns the video itself', () {
      expect(
        pickSongAudioCandidate(
          [row('vid', 'Boom Shaka', 'KR\$NA', 212)],
          title: 'Boom Shaka',
          artist: 'KR\$NA',
          durationMs: null,
          excludeId: 'vid',
        ),
        isNull,
      );
    });

    test('a remix only matches when the song is one', () {
      final rows = [row('r', 'Song (Remix)', 'Asha Singer', 200)];
      expect(
        pickSongAudioCandidate(
          rows,
          title: 'Song',
          artist: 'Asha Singer',
          durationMs: null,
        ),
        isNull,
      );
      expect(
        pickSongAudioCandidate(
          rows,
          title: 'Song (Remix)',
          artist: 'Asha Singer',
          durationMs: null,
        ),
        'r',
      );
    });
  });
}
