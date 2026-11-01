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
}
