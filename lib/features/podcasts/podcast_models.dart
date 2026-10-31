/// YouTube Music podcast surfaces. Episodes are normal video ids, so the
/// existing player can open them once a row is remembered for resume.
class PodcastShow {
  final String showId;
  final String title;
  final String publisher;
  final String description;
  final String artworkUrl;

  const PodcastShow({
    required this.showId,
    required this.title,
    this.publisher = '',
    this.description = '',
    this.artworkUrl = '',
  });
}

class PodcastEpisode {
  final String videoId;
  final String title;
  final String showId;
  final String showTitle;
  final String description;
  final String artworkUrl;
  final int durationMs;
  final String publishedLabel;

  const PodcastEpisode({
    required this.videoId,
    required this.title,
    this.showId = '',
    this.showTitle = '',
    this.description = '',
    this.artworkUrl = '',
    this.durationMs = 0,
    this.publishedLabel = '',
  });

  PodcastEpisode copyWith({
    String? showId,
    String? showTitle,
  }) =>
      PodcastEpisode(
        videoId: videoId,
        title: title,
        showId: showId ?? this.showId,
        showTitle: showTitle ?? this.showTitle,
        description: description,
        artworkUrl: artworkUrl,
        durationMs: durationMs,
        publishedLabel: publishedLabel,
      );
}

class PodcastShelf {
  final String title;
  final List<PodcastShow> shows;
  final List<PodcastEpisode> episodes;

  const PodcastShelf({
    required this.title,
    this.shows = const [],
    this.episodes = const [],
  });
}

class PodcastShowPage {
  final PodcastShow show;
  final List<PodcastEpisode> episodes;
  final String? continuation;

  const PodcastShowPage({
    required this.show,
    this.episodes = const [],
    this.continuation,
  });
}

class PodcastEpisodePage {
  final List<PodcastEpisode> episodes;
  final String? continuation;

  const PodcastEpisodePage({
    this.episodes = const [],
    this.continuation,
  });
}
