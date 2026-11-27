/// Shared parsing helpers for downloaded series file names.
///
/// Downloaded episode titles look like `Episode 05 - Name (1080p)` and their
/// paths often repeat the same `S01E05` pattern. Keeping the regexes in one
/// place makes every launch site agree on which episode is being played.
class EpisodeParser {
  EpisodeParser._();

  static final RegExp _episodePattern = RegExp(
    r'(?:episode\s*|(?<![a-zA-Z])e)(\d+)',
    caseSensitive: false,
  );
  static final RegExp _seasonPattern = RegExp(
    r'(?:season\s*|(?<![a-zA-Z])s)(\d+)',
    caseSensitive: false,
  );

  /// Returns the episode number found in [text], or `null`.
  static int? episode(String text) {
    final match = _episodePattern.firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  /// Returns the season number found in [text], or `null`.
  static int? season(String text) {
    final match = _seasonPattern.firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  /// Normalised series name used to group episodes that were downloaded one
  /// by one (those tasks have no [DownloadTask.series] metadata). Titles look
  /// like `Devil May Cry - Season 1 · Episode 1 · Inferno (720p)`; everything
  /// from the season marker onwards is the episode-specific part.
  static String seriesName(String title) {
    final cut = title.indexOf(
      RegExp(r'\b(season|episode)\b', caseSensitive: false),
    );
    var name = cut >= 0 ? title.substring(0, cut) : title;
    if (name.trim().isEmpty) {
      // Titles that start with "Episode NN" have no separate series prefix;
      // keep what is left after the number instead of returning an empty key.
      name = title
          .replaceFirst(_episodePattern, '')
          .replaceFirst(
            RegExp(
              r'\s*\([^)]*(1080p|720p|480p|4k|fhd|hd|sd)[^)]*\)\s*$',
              caseSensitive: false,
            ),
            '',
          );
    }
    name = name.replaceFirst(RegExp(r'^\s*[-•|:]\s*'), '').trim();
    name = name.replaceFirst(RegExp(r'\s*[-•|:]\s*$'), '').trim();
    return name.toLowerCase();
  }

  /// Human readable episode name: strips the leading `Episode NN - ` part and
  /// any trailing `(quality)` chunk the download manager appends.
  static String episodeName(String title) {
    var name = title.replaceFirst(_episodePattern, '').trim();
    if (name.startsWith('-')) name = name.substring(1).trim();
    if (name.startsWith(':')) name = name.substring(1).trim();
    name = name
        .replaceFirst(
          RegExp(
            r'\s*\([^)]*(1080p|720p|480p|4k|fhd|hd|sd)[^)]*\)\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return name.isEmpty ? 'Episode' : name;
  }
}
