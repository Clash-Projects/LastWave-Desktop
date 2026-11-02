import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Embedded title, artist, and album. Filename parsing is the fallback
/// when a file has no ID3v2, ID3v1, or FLAC Vorbis comment.
class LocalAudioTags {
  final String title;
  final String artist;
  final String album;
  final String year;
  final Uint8List? coverBytes;

  const LocalAudioTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.year = '',
    this.coverBytes,
  });

  static LocalAudioTags read(String path, {String filename = ''}) {
    LocalAudioTags tags = const LocalAudioTags();
    try {
      final file = File(path);
      final length = file.lengthSync();
      if (length <= 0) return _fromFilename(filename);
      final raf = file.openSync();
      try {
        final headLen = length < 262144 ? length : 262144;
        final head = raf.readSync(headLen);
        tags = _id3v2(head) ??
            _flac(head) ??
            _mp4(head) ??
            const LocalAudioTags();
        if (tags.title.isEmpty && length > 128) {
          raf.setPositionSync(length - 128);
          final tail = raf.readSync(128);
          final v1 = _id3v1(tail);
          if (v1 != null) {
            tags = LocalAudioTags(
              title: tags.title.isNotEmpty ? tags.title : v1.title,
              artist: tags.artist.isNotEmpty ? tags.artist : v1.artist,
              album: tags.album.isNotEmpty ? tags.album : v1.album,
              year: tags.year,
              coverBytes: tags.coverBytes,
            );
          }
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    if (tags.title.isEmpty) {
      final named = _fromFilename(filename);
      return LocalAudioTags(
        title: named.title,
        artist: tags.artist.isNotEmpty ? tags.artist : named.artist,
        album: tags.album,
        year: tags.year,
        coverBytes: tags.coverBytes,
      );
    }
    if (tags.artist.isEmpty) {
      final named = _fromFilename(filename);
      return LocalAudioTags(
        title: tags.title,
        artist: named.artist,
        album: tags.album,
        year: tags.year,
        coverBytes: tags.coverBytes,
      );
    }
    return tags;
  }

  /// Same rule as a dropped file: `Artist - Title`, else the whole name.
  static LocalAudioTags _fromFilename(String filename) {
    final base = filename.replaceAll(RegExp(r'\.\w+$'), '');
    final parts = base.split(' - ');
    if (parts.length > 1) {
      return LocalAudioTags(
        artist: parts.first.trim(),
        title: parts.sublist(1).join(' - ').trim(),
      );
    }
    return LocalAudioTags(title: base.trim(), artist: 'Local file');
  }

  static LocalAudioTags? _id3v2(Uint8List bytes) {
    if (bytes.length < 10) return null;
    if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) {
      return null;
    }
    final version = bytes[3];
    if (version < 3 || version > 4) return null;
    final tagSize = _synchsafe(bytes, 6);
    var offset = 10;
    final end = offset + tagSize;
    final limit = end < bytes.length ? end : bytes.length;
    String title = '';
    String artist = '';
    String album = '';
    String year = '';
    Uint8List? cover;
    while (offset + 10 <= limit) {
      final id = ascii(bytes, offset, 4);
      if (id.isEmpty || id.codeUnitAt(0) == 0) break;
      final size = version == 4
          ? _synchsafe(bytes, offset + 4)
          : _u32(bytes, offset + 4);
      offset += 10;
      if (size <= 0 || offset + size > bytes.length) break;
      final frame = Uint8List.sublistView(bytes, offset, offset + size);
      offset += size;
      if (id == 'TIT2' ||
          id == 'TPE1' ||
          id == 'TALB' ||
          id == 'TYER' ||
          id == 'TDRC' ||
          id == 'TDRL') {
        final text = _id3Text(frame);
        if (id == 'TIT2' && title.isEmpty) title = text;
        if (id == 'TPE1' && artist.isEmpty) artist = text;
        if (id == 'TALB' && album.isEmpty) album = text;
        if (year.isEmpty &&
            (id == 'TYER' || id == 'TDRC' || id == 'TDRL')) {
          year = _yearOf(text);
        }
      } else if (id == 'APIC' && cover == null) {
        cover = _apicBytes(frame);
      }
    }
    if (title.isEmpty && artist.isEmpty && album.isEmpty && cover == null) {
      return null;
    }
    return LocalAudioTags(
      title: title,
      artist: artist,
      album: album,
      year: year,
      coverBytes: cover,
    );
  }

  static LocalAudioTags? _id3v1(Uint8List bytes) {
    if (bytes.length < 128) return null;
    if (ascii(bytes, 0, 3) != 'TAG') return null;
    final title = _latin1(bytes, 3, 30);
    final artist = _latin1(bytes, 33, 30);
    final album = _latin1(bytes, 63, 30);
    if (title.isEmpty && artist.isEmpty) return null;
    return LocalAudioTags(title: title, artist: artist, album: album);
  }

  static LocalAudioTags? _flac(Uint8List bytes) {
    if (bytes.length < 8) return null;
    if (ascii(bytes, 0, 4) != 'fLaC') return null;
    var offset = 4;
    while (offset + 4 <= bytes.length) {
      final header = bytes[offset];
      final last = (header & 0x80) != 0;
      final type = header & 0x7F;
      final size = (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      offset += 4;
      if (size < 0 || offset + size > bytes.length) break;
      if (type == 4 && size > 4) {
        final block = Uint8List.sublistView(bytes, offset, offset + size);
        final tags = _vorbis(block);
        if (tags != null) return tags;
      }
      offset += size;
      if (last) break;
    }
    return null;
  }

  static LocalAudioTags? _vorbis(Uint8List block) {
    if (block.length < 8) return null;
    final vendorLen = _u32le(block, 0);
    var offset = 4 + vendorLen;
    if (offset + 4 > block.length) return null;
    final count = _u32le(block, offset);
    offset += 4;
    String title = '';
    String artist = '';
    String album = '';
    String year = '';
    for (var i = 0; i < count; i++) {
      if (offset + 4 > block.length) break;
      final len = _u32le(block, offset);
      offset += 4;
      if (len < 0 || offset + len > block.length) break;
      final comment = utf8.decode(
        Uint8List.sublistView(block, offset, offset + len),
        allowMalformed: true,
      );
      offset += len;
      final eq = comment.indexOf('=');
      if (eq <= 0) continue;
      final key = comment.substring(0, eq).toUpperCase();
      final value = comment.substring(eq + 1).trim();
      if (value.isEmpty) continue;
      if (key == 'TITLE' && title.isEmpty) title = value;
      if (key == 'ARTIST' && artist.isEmpty) artist = value;
      if (key == 'ALBUM' && album.isEmpty) album = value;
      if (year.isEmpty && (key == 'DATE' || key == 'YEAR')) {
        year = _yearOf(value);
      }
    }
    if (title.isEmpty && artist.isEmpty) return null;
    return LocalAudioTags(
      title: title,
      artist: artist,
      album: album,
      year: year,
    );
  }

  /// Tags from the start of an audio payload, used before a download is
  /// written so a year folder can be chosen.
  static LocalAudioTags fromHead(Uint8List bytes) =>
      _id3v2(bytes) ?? _flac(bytes) ?? _mp4(bytes) ?? const LocalAudioTags();

  static String yearIn(String value) => _yearOf(value);

  static String _yearOf(String value) {
    final match = RegExp(r'(?:19|20)\d{2}').firstMatch(value);
    return match?.group(0) ?? '';
  }

  static Uint8List? _apicBytes(Uint8List frame) {
    if (frame.length < 6) return null;
    var i = 1;
    while (i < frame.length && frame[i] != 0) {
      i++;
    }
    i += 2;
    if (i >= frame.length) return null;
    final encoding = frame[0];
    if (encoding == 1 || encoding == 2) {
      while (i + 1 < frame.length && !(frame[i] == 0 && frame[i + 1] == 0)) {
        i += 2;
      }
      i += 2;
    } else {
      while (i < frame.length && frame[i] != 0) {
        i++;
      }
      i++;
    }
    if (i >= frame.length - 8) return null;
    return Uint8List.sublistView(frame, i);
  }

  static LocalAudioTags? _mp4(Uint8List bytes) {
    String title = '';
    String artist = '';
    String album = '';
    String year = '';
    Uint8List? cover;
    void walk(int start, int end, {bool ilst = false}) {
      var offset = start;
      while (offset + 8 <= end) {
        final size = _u32(bytes, offset);
        if (size < 8 || offset + size > end) break;
        final type = ascii(bytes, offset + 4, 4);
        final next = offset + size;
        var child = offset + 8;
        if (ilst && type != 'data') {
          if (child + 8 <= next && ascii(bytes, child + 4, 4) == 'data') {
            final payload = child + 16;
            if (payload < next) {
              final raw = Uint8List.sublistView(bytes, payload, next);
              final text = _trim(utf8.decode(raw, allowMalformed: true));
              if (type == '©nam' && title.isEmpty) title = text;
              if ((type == '©ART' || type == 'aART') && artist.isEmpty) {
                artist = text;
              }
              if (type == '©alb' && album.isEmpty) album = text;
              if (type == '©day' && year.isEmpty) year = _yearOf(text);
              if (type == 'covr' && cover == null && raw.length > 32) {
                cover = raw;
              }
            }
          }
        } else if (type == 'moov' ||
            type == 'udta' ||
            type == 'ilst' ||
            type == 'trak') {
          walk(child, next, ilst: type == 'ilst' || ilst);
        } else if (type == 'meta' && child + 4 <= next) {
          walk(child + 4, next, ilst: ilst);
        }
        offset = next;
      }
    }

    walk(0, bytes.length);
    if (title.isEmpty && artist.isEmpty && album.isEmpty && cover == null) {
      return null;
    }
    return LocalAudioTags(
      title: title,
      artist: artist,
      album: album,
      year: year,
      coverBytes: cover,
    );
  }

  static String _id3Text(Uint8List frame) {
    if (frame.isEmpty) return '';
    final encoding = frame[0];
    final data = Uint8List.sublistView(frame, 1);
    try {
      if (encoding == 0) return _trim(latin1.decode(data));
      if (encoding == 3) return _trim(utf8.decode(data, allowMalformed: true));
      if (encoding == 1 || encoding == 2) {
        var start = 0;
        var le = true;
        if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
          start = 2;
          le = true;
        } else if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
          start = 2;
          le = false;
        }
        final units = <int>[];
        for (var i = start; i + 1 < data.length; i += 2) {
          final unit = le
              ? (data[i] | (data[i + 1] << 8))
              : ((data[i] << 8) | data[i + 1]);
          if (unit == 0) break;
          units.add(unit);
        }
        return _trim(String.fromCharCodes(units));
      }
    } catch (_) {}
    return '';
  }

  static String _latin1(Uint8List bytes, int start, int length) {
    final end = start + length;
    if (end > bytes.length) return '';
    final slice = Uint8List.sublistView(bytes, start, end);
    final cut = slice.indexOf(0);
    final text = latin1.decode(cut >= 0 ? slice.sublist(0, cut) : slice);
    return text.trim();
  }

  static String ascii(Uint8List bytes, int start, int length) {
    if (start + length > bytes.length) return '';
    return latin1.decode(Uint8List.sublistView(bytes, start, start + length));
  }

  static int _synchsafe(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _u32(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _u32le(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  static String _trim(String value) =>
      value.replaceAll('\u0000', '').trim();
}
