/// Subfolder layout for new downloads.
///
/// Ids match Android `DownloadFolderStructure`. Existing files stay put
/// until the user runs Reorganize.
enum DownloadFolderLayout {
  flat('flat', 'Flat', 'Music/song.flac'),
  artistAlbum('artist_album', 'Artist/Album', 'Artist/Album/'),
  artistYearAlbum(
    'artist_year_album',
    'Artist/[Year] Album',
    'Artist/[2025] Album/',
  ),
  albumOnly('album_only', 'Album', 'Album/'),
  yearAlbum('year_album', '[Year] Album', '[2025] Album/');

  final String id;
  final String label;
  final String example;
  const DownloadFolderLayout(this.id, this.label, this.example);

  static DownloadFolderLayout fromId(String? id) {
    switch (id) {
      case 'artist_album':
      case 'artist_album_singles':
        return artistAlbum;
      case 'artist_year_album':
        return artistYearAlbum;
      case 'album_only':
        return albumOnly;
      case 'year_album':
        return yearAlbum;
      case 'artist_album_singles_flat':
        return artistAlbum;
      default:
        return flat;
    }
  }
}

/// Relative folder under the download root. Empty means flat.
///
/// Port of `TrackDownloadManager.downloadSubpath`.
String downloadSubpath({
  required DownloadFolderLayout structure,
  required String artist,
  String album = '',
  String? albumArtist,
  String year = '',
}) {
  if (structure == DownloadFolderLayout.flat) return '';
  var folderArtist = (albumArtist != null && albumArtist.trim().isNotEmpty)
      ? albumArtist
      : artist;
  folderArtist = primaryDownloadArtist(folderArtist);
  folderArtist = sanitizeDownloadSegment(folderArtist);
  if (folderArtist.isEmpty) folderArtist = 'Unknown Artist';
  final rawAlbum = album.trim();
  final isSingle =
      rawAlbum.isEmpty || rawAlbum.toLowerCase() == 'singles';
  var albumSeg = sanitizeDownloadSegment(rawAlbum);
  if (albumSeg.isEmpty) albumSeg = 'Singles';
  final yearDigits = year.replaceAll(RegExp(r'\D'), '');
  final yearSeg =
      yearDigits.length >= 4 ? yearDigits.substring(0, 4) : '';
  final yearAlbumSeg =
      yearSeg.length == 4 && !isSingle ? '[$yearSeg] $albumSeg' : albumSeg;
  final List<String> segments;
  switch (structure) {
    case DownloadFolderLayout.flat:
      segments = const [];
    case DownloadFolderLayout.artistAlbum:
      segments = isSingle
          ? [folderArtist, 'Singles']
          : [folderArtist, albumSeg];
    case DownloadFolderLayout.artistYearAlbum:
      segments = isSingle
          ? [folderArtist, 'Singles']
          : [folderArtist, yearAlbumSeg];
    case DownloadFolderLayout.albumOnly:
      segments = [isSingle ? 'Singles' : albumSeg];
    case DownloadFolderLayout.yearAlbum:
      segments = [isSingle ? 'Singles' : yearAlbumSeg];
  }
  return segments.where((s) => s.trim().isNotEmpty).join('/');
}

/// "A feat. B", "A, B", "A & B", "A x B" → "A".
String primaryDownloadArtist(String artist) {
  var name = artist.trim();
  final feat = RegExp(
    r'\s+(feat\.?|ft\.?|featuring|with)\s+.*$',
    caseSensitive: false,
  ).firstMatch(name);
  if (feat != null) {
    name = name.substring(0, feat.start).trim();
  }
  if (name.isEmpty) name = artist.trim();
  final split = name.split(RegExp(r'[,;&/、×]'));
  name = split.first.trim();
  if (name.isEmpty) name = artist.trim();
  name = name.split(RegExp(r'\s+x\s+', caseSensitive: false)).first.trim();
  return name.isEmpty ? artist.trim() : name;
}

String sanitizeDownloadSegment(String raw) {
  var name = raw.trim();
  if (name.contains('/') || name.contains('\\')) {
    name = name.split(RegExp(r'[\\/]')).last.trim();
  }
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  while (name.startsWith('.') || name.startsWith('_')) {
    name = name.substring(1).trim();
  }
  while (name.endsWith('.') || name.endsWith('_')) {
    if (name.isEmpty) break;
    name = name.substring(0, name.length - 1).trim();
  }
  if (name.length > 80) name = name.substring(0, 80).trim();
  if (name.isEmpty || name == '.' || name == '..') return '';
  return name;
}
