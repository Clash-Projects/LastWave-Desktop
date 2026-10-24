import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/khinsider/khinsider_parser.dart';

// Fixtures mirror the structure of KHInsider pages (search table, album
// songlist, track page links). Hosts and file names are made up. Same
// fixtures as LastWave-Native's KhInsiderParserTest.

const _searchHtml = r'''
<html><body><div id="pageContent">
<p>Found 373 matching albums.</p>
<table class="albumList">
  <tr><th></th><th><a href="/search?sort=name">Album</a></th><th>Platform</th><th>Type</th><th><a href="#">Year</a></th></tr>
  <tr>
    <td><a href="https://downloads.khinsider.com/game-soundtracks/album/zelda-one-2014"><img src="https://img.example/soundtracks/zelda-one-2014/thumbs_small/cover.png"></a></td>
    <td><a href="https://downloads.khinsider.com/game-soundtracks/album/zelda-one-2014">Zelda &amp; Link - One</a></td>
    <td><a href="https://downloads.khinsider.com/game-soundtracks/cd-i">CD-i</a></td>
    <td>Arrangement</td>
    <td>2014</td>
  </tr>
  <tr>
    <td><a href="/game-soundtracks/album/oot"><img src="/thumbs/oot.jpg"></a></td>
    <td><a href="/game-soundtracks/album/oot">Ocarina of Time</a></td>
    <td><a href="/game-soundtracks/nintendo-64">N64</a></td>
    <td>Soundtrack</td>
    <td>1998</td>
  </tr>
</table>
</div></body></html>''';

const _albumHtml = r'''
<html><body><div id="pageContent">
<h2>Minecraft Soundtrack - Volume Alpha</h2>
<table><tr><td><a href="https://img.example/soundtracks/minecraft/cover.png"><img src="https://img.example/soundtracks/minecraft/thumbs/cover.png"></a></td></tr></table>
<p align="left">
  Platforms: <a href="/game-soundtracks/android">Android</a>, <a href="/game-soundtracks/windows">Windows</a><br>
  Year: <b>2011</b><br>
  Published by: <a href="/game-soundtracks/publisher/mojang">Mojang</a><br>
  Number of Files: <b>3</b><br>
  Date Added: <b>Apr 23rd, 2021</b><br>
  Album type: <a href="/game-soundtracks/ost">Soundtrack</a><br>
</p>
<table id="songlist">
  <tr id="songlist_header"><th>&nbsp;</th><th>CD</th><th>#</th><th colspan="2">Song Name</th><th><b>MP3</b></th><th><b>FLAC</b></th><th></th><th></th></tr>
  <tr>
    <td><div class="playTrack"></div></td><td>1</td><td>1.</td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/1-01.%2520Key.mp3">Key</a></td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/1-01.%2520Key.mp3">1:05</a></td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/1-01.%2520Key.mp3">1.68 MB</a></td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/1-01.%2520Key.mp3">2.41 MB</a></td>
    <td><a href="/game-soundtracks/album/minecraft/1-01.%2520Key.mp3"><i>get_app</i></a></td><td><i>playlist_add</i></td>
  </tr>
  <tr>
    <td></td><td>1</td><td>2.</td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/1-02.%2520Door.mp3">Door</a></td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/1-02.%2520Door.mp3">1:51</a></td>
    <td>3.22 MB</td><td>7.49 MB</td><td></td><td></td>
  </tr>
  <tr>
    <td></td><td>2</td><td>1.</td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/2-01.%2520Subwoofer%2520Lullaby.mp3">Subwoofer Lullaby</a></td>
    <td class="clickable-row"><a href="/game-soundtracks/album/minecraft/2-01.%2520Subwoofer%2520Lullaby.mp3">1:03:29</a></td>
    <td>5.38 MB</td><td>10.00 MB</td><td></td><td></td>
  </tr>
  <tr id="songlist_footer"><th colspan="4">Total:</th><th>6:25</th><th>10 MB</th><th>20 MB</th></tr>
</table>
<table><tr><td><a href="/game-soundtracks/album/other">Other album</a></td></tr></table>
</div></body></html>''';

const _trackHtml = r'''
<html><body><div id="pageContent">
<p>Album name: <b>Minecraft</b></p>
<p><a href="https://files.example/soundtracks/minecraft/abcd/1-01.%20Key.mp3"><span>Click here to download as MP3</span></a></p>
<p><a href="https://files.example/soundtracks/minecraft/efgh/1-01.%20Key.flac"><span>Click here to download as FLAC</span></a></p>
<p><a href="https://files.example/soundtracks/minecraft/abcd/1-01.%20Key.mp3">https://files.example/â€¦</a></p>
<p><a href="https://downloads.khinsider.com/forums">Forums</a></p>
</div></body></html>''';

const _listHtml = r'''
<html><body><div id="pageContent">
<p>Found 6586 albums!</p>
<table class="albumList">
  <tr><th></th><th>Album</th><th>Platform</th><th>Type</th><th>Year</th></tr>
  <tr><td><a href="/game-soundtracks/album/a-2021"><img src="/t/a.jpg"></a></td><td><a href="/game-soundtracks/album/a-2021">A</a></td><td>Switch</td><td>Soundtrack</td><td>2021</td></tr>
</table>
<a href="https://downloads.khinsider.com/game-soundtracks/nintendo-switch?page=2">2</a>
</div></body></html>''';

const _top40Html = r'''
<table><tr><th></th><th>#</th><th>Album</th><th></th></tr>
<tr><td><a href="https://downloads.khinsider.com/game-soundtracks/album/minecraft"><img src="https://img.example/m.png"></a></td>
<td>1.</td><td><a href="https://downloads.khinsider.com/game-soundtracks/album/minecraft">Minecraft (2011)</a></td><td><i>remove</i></td></tr></table>''';

const _platformsHtml = r'''
<div id="pageContent">
  <a href="/game-soundtracks/nintendo-switch">Switch</a>
  <a href="/game-soundtracks/pc-9801">PC-98</a>
  <a href="/game-soundtracks/album/minecraft">Minecraft</a>
  <a href="/game-soundtracks/year/2024">2024</a>
  <a href="/game-soundtracks/ost">Soundtracks</a>
  <a href="/forums">Forums</a>
</div>''';

void main() {
  test('parses search rows by header name', () {
    final results = KhInsiderParser.parseSearch(_searchHtml);
    expect(results, hasLength(2));
    final first = results[0];
    expect(first.id, 'zelda-one-2014');
    expect(first.name, 'Zelda & Link - One');
    expect(first.platform, 'CD-i');
    expect(first.type, 'Arrangement');
    expect(first.year, '2014');
    expect(
      first.thumbnailUrl,
      'https://img.example/soundtracks/zelda-one-2014/thumbs_small/cover.png',
    );
    // Relative links resolve against the site.
    expect(
      results[1].thumbnailUrl,
      'https://downloads.khinsider.com/thumbs/oot.jpg',
    );
  });

  test('parses album page', () {
    final album = KhInsiderParser.parseAlbum('minecraft', _albumHtml)!;
    expect(album.name, 'Minecraft Soundtrack - Volume Alpha');
    expect(album.formats, ['mp3', 'flac']);
    expect(album.hasFlac, isTrue);
    expect(album.platforms, ['Android', 'Windows']);
    expect(album.year, '2011');
    expect(album.publisher, 'Mojang');
    expect(album.type, 'Soundtrack');
    expect(
      album.coverUrl,
      'https://img.example/soundtracks/minecraft/thumbs/cover.png',
    );
    expect(album.tracks.map((t) => t.name), [
      'Key',
      'Door',
      'Subwoofer Lullaby',
    ]);
    final key = album.tracks[0];
    // The encoded href is kept exactly (KHInsider double-encodes spaces).
    expect(key.pagePath, '/game-soundtracks/album/minecraft/1-01.%2520Key.mp3');
    expect(key.number, 1);
    expect(key.disc, 1);
    expect(key.durationSeconds, 65);
    expect(album.tracks[2].disc, 2);
    expect(album.tracks[2].durationSeconds, 3809);
  });

  test('album without song list is null', () {
    expect(
      KhInsiderParser.parseAlbum(
        'x',
        '<html><body><div id=pageContent><p>No such album</p></div></body></html>',
      ),
      isNull,
    );
  });

  test('picks the chosen format and falls back to MP3', () {
    final files = KhInsiderParser.parseTrackFiles(_trackHtml);
    expect(files.keys, ['mp3', 'flac']);
    expect(
      KhInsiderParser.pickFile(files, KhFormat.flac),
      endsWith('efgh/1-01.%20Key.flac'),
    );
    expect(
      KhInsiderParser.pickFile(files, KhFormat.mp3),
      endsWith('abcd/1-01.%20Key.mp3'),
    );
    final mp3Only = {'mp3': files['mp3']!};
    expect(KhInsiderParser.pickFile(mp3Only, KhFormat.flac), endsWith('.mp3'));
    expect(KhInsiderParser.pickFile(const {}, KhFormat.flac), isNull);
  });

  test('playback URI round-trips the encoded page', () {
    const page =
        '/game-soundtracks/album/minecraft/2-01.%2520Subwoofer%2520Lullaby.mp3';
    final uri = KhInsiderParser.playbackUri(page);
    expect(uri, startsWith('khinsider://track?page='));
    expect(KhInsiderParser.isPlaybackUri(uri), isTrue);
    expect(KhInsiderParser.pagePathOf(uri), page);
    expect(KhInsiderParser.pagePathOf('https://example.com/a.mp3'), isNull);
    expect(
      KhInsiderParser.trackPageUrl(page),
      'https://downloads.khinsider.com$page',
    );
  });

  test('recognises album redirects and Cloudflare pages', () {
    expect(
      KhInsiderParser.isAlbumPage(
        'https://downloads.khinsider.com/game-soundtracks/album/minecraft',
      ),
      isTrue,
    );
    expect(
      KhInsiderParser.isAlbumPage(
        'https://downloads.khinsider.com/game-soundtracks/album/minecraft/1-01.mp3',
      ),
      isFalse,
    );
    expect(
      KhInsiderParser.isAlbumPage(
        'https://downloads.khinsider.com/search?search=zelda',
      ),
      isFalse,
    );
    expect(
      KhInsiderParser.albumIdOf('/game-soundtracks/album/minecraft/1-01.mp3'),
      'minecraft',
    );
    expect(
      KhInsiderParser.isCloudflareChallenge(
        '<html><head><title>Just a moment...</title>',
      ),
      isTrue,
    );
    expect(
      KhInsiderParser.isCloudflareBlock(
        '<title>Attention Required! | Cloudflare</title>',
      ),
      isTrue,
    );
    expect(KhInsiderParser.isCloudflareChallenge(_albumHtml), isFalse);
    expect(
      KhInsiderParser.searchUrl('zelda ocarina'),
      'https://downloads.khinsider.com/search?search=zelda+ocarina',
    );
  });

  test('parses a list page and its next page', () {
    final page = KhInsiderParser.parseAlbumPage(_listHtml, 1);
    expect(page.albums.map((a) => a.id), ['a-2021']);
    expect(page.hasNext, isTrue);
    expect(KhInsiderParser.parseAlbumPage(_listHtml, 2).hasNext, isFalse);
  });

  test('parses Top 40 with rank column', () {
    final albums = KhInsiderParser.parseSearch(_top40Html);
    expect(albums, hasLength(1));
    expect(albums[0].name, 'Minecraft (2011)');
    expect(albums[0].thumbnailUrl, 'https://img.example/m.png');
  });

  test('parses platform list skipping non-platform links', () {
    expect(KhInsiderParser.parsePlatforms(_platformsHtml), [
      ('nintendo-switch', 'Switch'),
      ('pc-9801', 'PC-98'),
    ]);
  });

  test('builds list URLs', () {
    expect(
      KhInsiderParser.listUrl('/top40', 1),
      'https://downloads.khinsider.com/top40',
    );
    expect(
      KhInsiderParser.listUrl('/game-soundtracks/year/2024', 3),
      'https://downloads.khinsider.com/game-soundtracks/year/2024?page=3',
    );
  });
}
