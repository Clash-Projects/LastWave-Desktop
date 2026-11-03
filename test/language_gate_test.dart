import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/matching/match_vocab.dart';
import 'package:lastwave_desktop/features/addons/addon_api.dart';

void main() {
  test('languages are read from words and scripts', () {
    expect(MatchVocab.languagesOf('Ayudha Pooja (Telugu)'), {'telugu'});
    expect(MatchVocab.languagesOf('तुम ही हो'), {'hindi'});
    expect(MatchVocab.languagesOf('Plain Title'), isEmpty);
  });

  test('an unasked language marker makes a release unfaithful', () {
    expect(
      AddonApi.isFaithfulVersion('Song (Hindi Version)',
          title: 'Song', artist: 'A'),
      isFalse,
    );
    expect(
      AddonApi.isFaithfulVersion('Song (Hindi Version)',
          title: 'Song (Hindi Version)', artist: 'A'),
      isTrue,
    );
    expect(
      AddonApi.isFaithfulVersion('Song', title: 'Song', artist: 'A'),
      isTrue,
    );
  });

  test('without a requested language the unmarked original wins', () {
    const tel = AddonTrack(id: '1', title: 'Song', album: 'Film (Telugu)');
    const orig = AddonTrack(id: '2', title: 'Song', album: 'Film');
    expect(
      AddonApi.gateLanguage([tel, orig], title: 'Song').map((t) => t.id),
      ['2'],
    );
    expect(
      AddonApi.gateLanguage([tel, orig], title: 'Song (Telugu)')
          .map((t) => t.id),
      ['1'],
    );
    expect(AddonApi.gateLanguage([tel, tel], title: 'Song'), hasLength(2));
  });
}
