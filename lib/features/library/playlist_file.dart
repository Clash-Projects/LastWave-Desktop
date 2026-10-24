/// Playlist file import: CSV / TSV exports (Exportify, Soundiiz, YouTube
/// Takeout, spreadsheets), M3U / M3U8 and plain text lists, read into
/// rows before they are matched to YouTube. Pure, never throws.
///
/// Port of LastWave-Native's CsvPlaylistImporter parser so a file that
/// imports on the phone imports the same way here.
library;

import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// One row read off a playlist file. [videoId] is set when the row carries
/// a YouTube link or id.
class PlaylistFileRow {
  final String title;
  final String artist;
  final String? album;
  final String? videoId;
  const PlaylistFileRow({
    required this.title,
    this.artist = '',
    this.album,
    this.videoId,
  });

  PlaylistFileRow withVideoId(String? id) =>
      PlaylistFileRow(title: title, artist: artist, album: album, videoId: id);

  /// Key used to collapse repeated rows before matching.
  String get identity => videoId != null
      ? 'id:$videoId'
      : 'text:${normalizeCell(title)}|${normalizeCell(artist)}';
}

/// Decodes file bytes: UTF-16 by BOM, else UTF-8, else Latin-1.
String decodePlaylistBytes(List<int> bytes) {
  String text;
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    text = _utf16(bytes.sublist(2), littleEndian: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    text = _utf16(bytes.sublist(2), littleEndian: false);
  } else {
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
    }
  }
  return text.startsWith('﻿') ? text.substring(1) : text;
}

String _utf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

/// "My_Playlist-2024.csv" -> "My Playlist 2024".
String suggestedPlaylistTitle(String filename) {
  final dot = filename.lastIndexOf('.');
  final base = (dot >= 0 ? filename.substring(0, dot) : filename)
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .trim();
  return base.isEmpty ? 'Imported Playlist' : base;
}

String normalizeCell(String value) => unorm
    .nfkc(value)
    .toLowerCase()
    .replaceAll(RegExp('[\'’"“”]'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ')
    .trim();

/// Reads [text] (the content of [filename]) into rows.
List<PlaylistFileRow> parsePlaylistFile(String text, String filename) {
  final name = filename.toLowerCase();
  final lines = _lines(text).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return const [];
  if (name.endsWith('.m3u') ||
      name.endsWith('.m3u8') ||
      lines.first.toUpperCase() == '#EXTM3U') {
    return _parseM3u(_lines(text).toList());
  }
  if (name.endsWith('.txt') &&
      !lines.any((l) => l.contains('\t')) &&
      !lines.first
          .split(RegExp('[,;]'))
          .map(normalizeCell)
          .every(
            (h) =>
                _titleHeaders.contains(h) ||
                _artistHeaders.contains(h) ||
                _urlHeaders.contains(h),
          )) {
    return lines
        .where((l) => !l.startsWith('#') && !l.startsWith('//'))
        .map(_parseTextTrack)
        .toList();
  }

  // Comment or separator directive lines at the top of CSV files
  // (Exportify, Soundiiz, Excel).
  final cleanedLines = lines
      .where(
        (l) =>
            !l.startsWith('#') &&
            !l.startsWith('//') &&
            !l.toLowerCase().startsWith('sep='),
      )
      .toList();
  if (cleanedLines.isEmpty) return const [];
  final cleanedText = cleanedLines.join('\n');

  final delimiter = _detectDelimiter(cleanedText);
  final records = _repairCollapsedRows(
    _parseRecords(cleanedText, delimiter),
    delimiter,
  ).where((r) => r.isNotEmpty && r.any((c) => c.trim().isNotEmpty)).toList();
  if (records.isEmpty) return const [];
  final first = records.first;
  final headers = first.map(normalizeCell).toList();
  final dataRows = records.skip(1).toList();

  bool isColMostlyNumeric(int col) {
    if (dataRows.isEmpty) return false;
    final nonBlank = [
      for (final r in dataRows)
        if (col < r.length && r[col].trim().isNotEmpty) r[col].trim(),
    ];
    if (nonBlank.isEmpty) return false;
    return nonBlank.where(_isDigits).length / nonBlank.length >= 0.7;
  }

  bool isExplicitIndexCol(int idx) {
    final h = idx < headers.length ? headers[idx] : '';
    return _indexHeaders.contains(h) ||
        (h == 'track' &&
            headers.any(
              (x) =>
                  _primaryTitleHeaders.contains(x) ||
                  _secondaryTitleHeaders.contains(x),
            )) ||
        isColMostlyNumeric(idx);
  }

  int indexOf(bool Function(String) test) => headers.indexWhere(test);

  var titleIndex = indexOf(_primaryTitleHeaders.contains);
  if (titleIndex < 0) titleIndex = indexOf(_secondaryTitleHeaders.contains);
  if (titleIndex < 0) {
    final t = indexOf((h) => h == 'track');
    titleIndex = t >= 0 && !isExplicitIndexCol(t) ? t : -1;
  }
  var artistIndex = indexOf(_primaryArtistHeaders.contains);
  if (artistIndex < 0) {
    artistIndex = indexOf(_secondaryArtistHeaders.contains);
  }
  final albumIndex = indexOf(_albumHeaders.contains);
  final urlIndex = indexOf(_urlHeaders.contains);

  // Only a multi-column first row without purely numeric cells is a header;
  // in a single-column file that guess is indistinguishable from data.
  final hasHeader =
      first.length >= 2 &&
      !first.any((c) => c.trim().isNotEmpty && _isDigits(c.trim())) &&
      (titleIndex >= 0 || artistIndex >= 0 || albumIndex >= 0 || urlIndex >= 0);
  if (first.length == 1 && !hasHeader) {
    return cleanedLines.map(_parseTextTrack).toList();
  }

  int firstColumn(bool Function(int) test, int fallback) {
    for (var i = 0; i < first.length; i++) {
      if (test(i)) return i;
    }
    return fallback;
  }

  final titleColumn = hasHeader && titleIndex >= 0
      ? titleIndex
      : hasHeader
      ? firstColumn(
          (i) =>
              i != artistIndex &&
              i != albumIndex &&
              i != urlIndex &&
              !isExplicitIndexCol(i),
          0,
        )
      : firstColumn((i) => !isExplicitIndexCol(i), 0);
  final artistColumn = hasHeader && artistIndex >= 0
      ? artistIndex
      : hasHeader
      ? -1
      : firstColumn((i) => i != titleColumn && !isColMostlyNumeric(i), 1);

  String cell(List<String> row, int i) =>
      i >= 0 && i < row.length ? row[i].trim() : '';

  final out = <PlaylistFileRow>[];
  for (final row in records.skip(hasHeader ? 1 : 0)) {
    if (hasHeader && _sameList(row.map(normalizeCell).toList(), headers)) {
      continue;
    }
    final titleCell = cell(row, titleColumn);
    final rawArtist = cell(row, artistColumn);
    String? videoId = urlIndex >= 0 ? youtubeIdOf(cell(row, urlIndex)) : null;
    if (videoId == null) {
      for (final c in row) {
        final t = c.trim().toLowerCase();
        if (t.startsWith('https://') || t.startsWith('http://')) {
          videoId = youtubeIdOf(c.trim());
          if (videoId != null) break;
        }
      }
    }
    final title = videoId != null && youtubeIdOf(titleCell) == videoId
        ? ''
        : titleCell;
    if (title.isEmpty && videoId == null) continue;

    var finalTitle = title;
    var finalArtist = rawArtist;
    if (finalArtist.isEmpty && finalTitle.isNotEmpty && videoId == null) {
      final parsed = _parseTextTrack(finalTitle);
      if (parsed.title.isNotEmpty && parsed.artist.isNotEmpty) {
        finalTitle = parsed.title;
        finalArtist = parsed.artist;
      }
    }
    final album = cell(row, albumIndex);
    out.add(
      PlaylistFileRow(
        title: finalTitle,
        artist: finalArtist,
        album: album.isEmpty ? null : album,
        videoId: videoId,
      ),
    );
  }
  return out;
}

Iterable<String> _lines(String text) =>
    const LineSplitter().convert(text).map((l) => l.trim());

bool _isDigits(String s) => RegExp(r'^\d+$').hasMatch(s);

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Splits rows that a stray unclosed quote collapsed together: the
/// swallowed lines each carry a normal row's field count, unlike a real
/// multi-line quoted field, which is left untouched.
List<List<String>> _repairCollapsedRows(
  List<List<String>> records,
  String delimiter,
) {
  final modal = _modalSize(records, minSize: 1);
  if (modal == null || modal < 2) return records;
  final repaired = <List<String>>[];
  for (final record in records) {
    final collapsed = record.indexWhere((c) => c.contains('\n'));
    if (collapsed < 0) {
      repaired.add(record);
      continue;
    }
    final lines = record[collapsed].split('\n');
    final swallowed = lines.skip(1).toList();
    final looksLikeUnclosedQuote =
        swallowed.isNotEmpty &&
        swallowed.every((l) => _cellsOf(l, delimiter).length == modal);
    if (!looksLikeUnclosedQuote) {
      repaired.add(record);
      continue;
    }
    repaired.add([
      ...record.take(collapsed),
      ..._cellsOf(lines.first, delimiter),
    ]);
    for (final l in swallowed) {
      repaired.add(_cellsOf(l, delimiter));
    }
  }
  return repaired;
}

List<String> _cellsOf(String line, String delimiter) {
  final r = _parseRecords(line, delimiter);
  return r.isNotEmpty ? r.first : [line.trim()];
}

/// Most frequent row length (at least [minSize]) and its count.
int? _modalSize(List<List<String>> rows, {int minSize = 2}) =>
    _modal(rows, minSize)?.key;

MapEntry<int, int>? _modal(List<List<String>> rows, int minSize) {
  final counts = <int, int>{};
  for (final r in rows) {
    if (r.length >= minSize) counts[r.length] = (counts[r.length] ?? 0) + 1;
  }
  MapEntry<int, int>? best;
  for (final e in counts.entries) {
    if (best == null || e.value > best.value) best = e;
  }
  return best;
}

/// Picks the delimiter that splits the file into consistent multi-column
/// rows. A raw count is not enough: a comma inside a tab-separated artist
/// field would tie with the real delimiter and shift every column.
String _detectDelimiter(String text) {
  var best = _delimiters.first;
  var bestScore = -1 << 30;
  for (final candidate in _delimiters) {
    final rows = _parseRecords(text, candidate).take(8).toList();
    if (rows.isEmpty) continue;
    final modal = _modal(rows, 2);
    if (modal == null) continue;
    final score =
        modal.value * 1000 +
        rows.fold<int>(0, (s, r) => s + (r.length - 1).clamp(0, 1 << 20));
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}

final _numbering = RegExp(r'^\s*(?:\[?\d+[.)\]]|\d+\s*[-–—])\s*');
final _bySeparator = RegExp(r'\s+by\s+', caseSensitive: false);
final _dashSeparator = RegExp(r'\s+[-–—|:]\s+');

/// "Artist - Title", "Title by Artist", "01. Artist - Title" or a bare link.
PlaylistFileRow _parseTextTrack(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return const PlaylistFileRow(title: '');
  final videoId = youtubeIdOf(trimmed);
  if (videoId != null) return PlaylistFileRow(title: '', videoId: videoId);
  final cleaned = trimmed.replaceFirst(_numbering, '').trim();
  if (cleaned.isEmpty) return const PlaylistFileRow(title: '');

  final by = _bySeparator.firstMatch(cleaned);
  if (by != null) {
    final title = cleaned.substring(0, by.start).trim();
    if (title.isNotEmpty) {
      return PlaylistFileRow(
        title: title,
        artist: cleaned.substring(by.end).trim(),
      );
    }
  }
  final sep = _dashSeparator.firstMatch(cleaned);
  if (sep == null) return PlaylistFileRow(title: cleaned);
  return PlaylistFileRow(
    title: cleaned.substring(sep.end).trim(),
    artist: cleaned.substring(0, sep.start).trim(),
  );
}

final _extinfArtist = RegExp(r'artist="([^"]+)', caseSensitive: false);
final _extinfTitle = RegExp(r'title="([^"]+)', caseSensitive: false);

List<PlaylistFileRow> _parseM3u(List<String> lines) {
  final tracks = <PlaylistFileRow>[];
  PlaylistFileRow? pending;
  for (final line in lines) {
    if (line.toUpperCase().startsWith('#EXTINF:')) {
      if (pending != null) tracks.add(pending);
      final info = line.substring(line.indexOf(':') + 1);
      final artist = _extinfArtist.firstMatch(info)?.group(1);
      final title = _extinfTitle.firstMatch(info)?.group(1);
      final comma = info.indexOf(',');
      pending = artist != null && title != null
          ? PlaylistFileRow(title: title, artist: artist)
          : _parseTextTrack(comma >= 0 ? info.substring(comma + 1) : '');
    } else if (line.isEmpty || line.startsWith('#')) {
      continue;
    } else {
      final videoId = youtubeIdOf(line);
      var file = line.substring(line.lastIndexOf('/') + 1);
      file = file.substring(file.lastIndexOf('\\') + 1);
      final dot = file.lastIndexOf('.');
      final track =
          pending ??
          (videoId != null
              ? PlaylistFileRow(title: '', videoId: videoId)
              : _parseTextTrack(dot >= 0 ? file.substring(0, dot) : file));
      tracks.add(track.withVideoId(videoId));
      pending = null;
    }
  }
  if (pending != null) tracks.add(pending);
  return tracks;
}

final _videoIdRegex = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// YouTube video id from a bare id or a youtube.com / youtu.be /
/// music.youtube.com link; null otherwise.
String? youtubeIdOf(String value) {
  final v = value.trim();
  if (_videoIdRegex.hasMatch(v)) return v;
  final lower = v.toLowerCase();
  if (!lower.startsWith('https://') && !lower.startsWith('http://')) {
    return null;
  }
  final uri = Uri.tryParse(v);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
    id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    id = uri.queryParameters['v'];
    final seg = uri.pathSegments;
    if (id == null &&
        seg.length >= 2 &&
        const {'shorts', 'embed', 'live', 'v'}.contains(seg.first)) {
      id = seg[1];
    }
  }
  return id != null && _videoIdRegex.hasMatch(id) ? id : null;
}

/// Parses delimited text, honouring quotes and doubled quotes. An unclosed
/// quote at end of input is treated as closed so the rows before it
/// survive.
List<List<String>> _parseRecords(String text, String delimiter) {
  final records = <List<String>>[];
  final row = <String>[];
  final field = StringBuffer();
  var quoted = false;

  void finishField() {
    row.add(field.toString().trim());
    field.clear();
  }

  void finishRow() {
    finishField();
    if (row.any((c) => c.isNotEmpty)) records.add(List.of(row));
    row.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"' && quoted && i + 1 < text.length && text[i + 1] == '"') {
      field.write('"');
      i++;
    } else if (c == '"' && (quoted || field.toString().trim().isEmpty)) {
      quoted = !quoted;
    } else if (c == delimiter && !quoted) {
      finishField();
    } else if ((c == '\n' || c == '\r') && !quoted) {
      finishRow();
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else {
      field.write(c);
    }
  }
  if (quoted || field.isNotEmpty || row.isNotEmpty) finishRow();
  return records;
}

const _delimiters = [',', ';', '\t', '|'];

const _indexHeaders = {
  'index',
  '#',
  'no',
  'no.',
  'number',
  'num',
  'track number',
  'track no',
  'track num',
  'track count',
  'track index',
  'track id',
  'position',
  'pos',
  'order',
  'disc',
  'disc number',
  'disc no',
  'disc num',
  'disc count',
  'side',
  'duration',
  'duration ms',
  'duration_ms',
  'time',
  'length',
  'bpm',
  'year',
  'date',
  'genre',
  'genres',
  'isrc',
  'key',
  'popularity',
  'bitrate',
  'added at',
  'added by',
};
const _primaryTitleHeaders = {
  'track name',
  'trackname',
  'song title',
  'songtitle',
  'track title',
  'tracktitle',
  'song name',
  'songname',
  'title',
  'titles',
  'video title',
  'item name',
  'audio title',
  'titre',
  'titres',
  'titulo',
  'titulos',
  'cancion',
  'canciones',
  'lied',
  'lieder',
  'titel',
};
const _secondaryTitleHeaders = {
  'song',
  'songs',
  'name',
  'music',
  'item',
  'headline',
};
final _titleHeaders = {
  ..._primaryTitleHeaders,
  ..._secondaryTitleHeaders,
  'track',
  'tracks',
};
const _primaryArtistHeaders = {
  'artist name s',
  'artist names',
  'artist name',
  'artistname',
  'track artist',
  'track artists',
  'lead artist',
  'primary artist',
  'main artist',
  'channel title',
  'channel name',
  'track artist name',
  'artiste',
  'artistes',
  'artista',
  'artistas',
  'interpret',
  'interpreten',
  'kuenstler',
  'künstler',
};
const _secondaryArtistHeaders = {
  'artist s',
  'artist',
  'artists',
  'channel',
  'uploader',
  'author',
  'creator',
  'performer',
  'performers',
  'singer',
  'singers',
  'band',
  'by',
};
final _artistHeaders = {..._primaryArtistHeaders, ..._secondaryArtistHeaders};
const _albumHeaders = {
  'album name',
  'albumname',
  'album',
  'albums',
  'release',
  'collection',
  'record',
  'album title',
  'album name s',
  'record title',
  'album_name',
  'album_title',
};
const _urlHeaders = {
  'url',
  'uri',
  'track url',
  'track uri',
  'youtube url',
  'video id',
  'videoid',
  'link',
  'track link',
  'spotify uri',
  'spotify url',
  'youtube link',
  'video url',
  'spotify id',
  'spotify track id',
  'id',
  'yt url',
  'youtube',
  'soundcloud url',
};
